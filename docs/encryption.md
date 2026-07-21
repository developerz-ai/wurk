# Argument encryption

Wurk can encrypt the **last positional argument** of a job before it reaches
Redis, and decrypt it again just before `perform` runs. It's a drop-in for
`Sidekiq::Enterprise::Crypto`, shipped free in the same gem — the Ent
initializer works unchanged on the one-line gem swap.

The whole feature is a client/server middleware pair:

| Stage | What happens | Where |
|-------|--------------|-------|
| Push | `args.last` is replaced by a JSON envelope `{v, iv, ct, tag}` | `Wurk::Encryption::ClientMiddleware` |
| Storage | Redis holds the envelope; no cleartext is ever written | `queue:*`, `retry`, `schedule`, `dead` |
| Dashboard | The envelope renders as the literal string `"<encrypted>"` | `Wurk::Encryption.redact_args` |
| Execute | The envelope is opened back into the original Ruby value | `Wurk::Encryption::ServerMiddleware` |

Aliases (`lib/wurk/compat.rb`): `Sidekiq::Enterprise::Crypto.enable/.enabled?`
delegates to `Wurk::Encryption`, and `Sidekiq::Encryption` is the same module.

---

## Threat model

Encryption here protects **payloads at rest in Redis** and everything
downstream of Redis:

- A dumped `RDB`/`AOF` file, a Redis replica, or a managed-Redis snapshot
  contains ciphertext, not card numbers.
- `redis-cli LRANGE queue:default 0 -1`, a Redis-side `MONITOR`, or any
  third-party tool that reads the queue sees the envelope only.
- The Wurk dashboard — including everyone you granted read access — sees
  `"<encrypted>"`.
- A retry or dead-set record keeps the ciphertext, so the secret is not
  re-exposed by a failure days later.

It does **not** protect against:

- **Anyone who can run your Ruby code.** The worker process holds the key and
  decrypts before `perform`. A Rails console, an injected gem, or a heap dump
  of a worker sees cleartext.
- **The transport.** The envelope travels to Redis over whatever socket you
  configured. Use `rediss://` (TLS) if in-transit confidentiality matters —
  encryption is orthogonal, not a substitute.
- **The earlier arguments.** Only the last positional argument is encrypted.
  Everything before it is plaintext in Redis, in the dashboard, and in error
  logs — by design (see below).
- **Backtraces and error messages.** If your code raises with the secret in the
  message, that message is stored plaintext on the retry/dead record.
- **Key loss.** There is no escrow. Lose a key version and every job still
  holding a payload at that version is unrecoverable.

---

## Enabling

Call `enable` once, at boot, from an initializer. The block is the **only** key
source — it maps `Integer version → 32-byte binary key`, so it can read a file,
an ENV var, or a KMS.

```ruby
# config/initializers/wurk.rb
Sidekiq::Enterprise::Crypto.enable(active_version: 1) do |version|
  File.binread("config/crypto/secret.#{Rails.env}.#{version}.key")
end
```

`Wurk::Encryption.enable(active_version: 1) { |v| … }` is the same call under
its native name. Both are idempotent: calling `enable` again rebinds the
resolver, clears the key cache, and installs the middleware at most once per
chain.

Then opt each job in:

```ruby
class ChargeCardJob
  include Sidekiq::Job
  sidekiq_options encrypt: true

  def perform(user_id, secret_bag)
    # secret_bag arrives as the original Ruby Hash — already decrypted.
    Payments.charge(user_id, secret_bag["pan"], secret_bag["cvv"])
  end
end
```

`encrypt: true` is a plain `sidekiq_options` key, so it also works per-push via
`ChargeCardJob.set(encrypt: true).perform_async(...)`.

Argument shape rules:

- `perform` **must** take at least two positional arguments. If there is no
  cleartext payload, pass `nil` first: `perform_async(nil, secret_bag)`.
- Only `args.last` is encrypted. Earlier args stay plaintext **on purpose** —
  they're what makes a job triageable in the dashboard (`user_id`,
  `order_id`, …) when you can't see the secret.
- The encrypted value can be any JSON-serializable Ruby value: String, Hash,
  Array, Integer. It round-trips through `JSON.dump` / `JSON.parse` (quirks
  mode), so it comes back with **string** hash keys, not symbols.

---

## The scheme

AES-256-GCM. Fresh 96-bit IV per push, 128-bit auth tag, no CBC fallback.

| Constant | Value |
|----------|-------|
| `CIPHER_NAME` | `aes-256-gcm` |
| `KEY_BYTES` | `32` (exact — not a minimum) |
| `IV_BYTES` | `12` |
| `TAG_BYTES` | `16` |
| `ENVELOPE_MARKER` | `__wurk_enc__` |

The envelope is a plain JSON object, not a base64 blob, so the `args` array in
Redis stays valid, inspectable JSON:

```json
{"__wurk_enc__": true, "v": 1, "iv": "…", "ct": "…", "tag": "…"}
```

The `__wurk_enc__` marker is the authoritative discriminator —
`Wurk::Encryption.envelope?` requires it plus all four fields, so a user Hash
that happens to have `v`/`iv`/`ct`/`tag` keys is never mistaken for ciphertext.
Overhead is roughly 150 bytes plus ~30% base64 growth on the payload.

> **Divergence from Sidekiq Enterprise.** Ent stores a base64 binary blob;
> Wurk stores this JSON envelope. Wurk both writes and reads its own format so
> it is self-consistent, but **encrypted payloads do not round-trip between
> Sidekiq Enterprise and Wurk**. If you are migrating with encrypted jobs
> already in Redis, drain them under Sidekiq Ent before swapping the gem.
> Everything else on the wire is byte-identical. (Spec:
> `docs/target/sidekiq-ent.md` §4.4.)

### Key requirements and sources

The resolver's return value is validated on first use per version:

- `nil` → `Wurk::Encryption::KeyMissingError` ("key resolver returned nil for
  version N").
- Wrong length → `Wurk::Encryption::Error` ("key for version N must be 32
  bytes, got X").
- The bytes are duped and forced to `ASCII-8BIT`, so an encoding-tagged String
  from `ENV` is fine — but a *hex or base64 string* is not: 32 bytes means 32
  raw bytes.

Generate one:

```ruby
File.binwrite("config/crypto/secret.production.1.key",
              OpenSSL::Cipher.new("aes-256-gcm").random_key)
```

Any source works, as long as the block returns those bytes:

```ruby
# config/initializers/wurk.rb
Sidekiq::Enterprise::Crypto.enable(active_version: 2) do |version|
  case version
  when 1 then Base64.strict_decode64(ENV.fetch("WURK_CRYPTO_KEY_V1"))
  when 2 then Base64.strict_decode64(ENV.fetch("WURK_CRYPTO_KEY_V2"))
  end
end
```

```ruby
# KMS — the block is called at most once per version per process (cached),
# so a network round-trip here is acceptable.
Sidekiq::Enterprise::Crypto.enable(active_version: 3) do |version|
  Aws::KMS::Client.new.decrypt(
    ciphertext_blob: File.binread("config/crypto/wrapped.#{version}.key")
  ).plaintext
end
```

Keys are cached per version, per process, for the life of the process
(`@key_cache`). A resolver that returns a *different* key for a version it
already answered will not be re-consulted — only `enable` (which resets the
cache) or a restart picks that up.

---

## Key rotation

`active_version` is the version used to **encrypt** new pushes. The resolver
must keep answering for every older version that still has payloads in flight —
`decrypt` reads the version out of the envelope's `v` field and asks the
resolver for that key, so old and new coexist with no downtime.

Step by step:

1. **Generate** `secret.production.2.key` (32 random bytes) and ship it
   everywhere Wurk runs — web dynos included, since they enqueue.
2. **Deploy the resolver first, keeping `active_version: 1`.** Every process
   can now *decrypt* v2, but still *encrypts* v1. This step exists so a
   partially-rolled deploy never produces a payload nobody can open.
3. **Deploy `active_version: 2`.** New pushes are v2. In-flight v1 payloads in
   `queue:*`, `retry`, `schedule`, and `dead` keep decrypting because the
   resolver still answers for version 1.
4. **Wait out the tail.** The long pole is the retry set (up to ~21 days at
   default retry settings) and anything scheduled far out. `dead` holds jobs
   for 6 months by default — a dead v1 job retried after you drop the key will
   fail permanently.
5. **Drop version 1** from the resolver only once no v1 payload remains.

Auditing the tail is manual — there is no built-in "which versions are still in
Redis" report. Scan the sets you care about:

```ruby
# rails runner — count payloads per crypto version still in the retry set
Wurk::RetrySet.new.group_by { |entry| entry.item.dig("args", -1, "v") }
              .transform_values(&:size)
```

`Wurk::RetrySet` / `Wurk::ScheduledSet` / `Wurk::DeadSet` all enumerate
`SortedEntry`s whose `#item` is the parsed job hash.

Because keys are cached per process, a rotation is picked up by a **restart or
a fresh `enable` call**, not by editing the key file in place.

---

## When decryption fails

A missing key, a key rotated away, or a tampered ciphertext is **terminal** —
it does not heal with time, so retrying it 25 times over ~21 days is a crash
loop with no upside. The server middleware therefore diverges from the spec
(`docs/target/sidekiq-ent.md` §4.6, which lets the `OpenSSL::Cipher::CipherError`
bubble into the normal retry pipeline) and instead:

1. Writes the job **straight to the dead set** (`Wurk::DeadSet#kill`), which
   fires your `death_handlers` — so on-call gets paged in under a second, not
   three weeks later.
2. Increments the statsd counter `jobs.encryption_error`, tagged
   `worker:<JobClass>` — alert on this.
3. Raises `Wurk::JobRetry::Skip`, which ACKs the job so it isn't re-fetched.

The dead record carries:

| Field | Value |
|-------|-------|
| `error_class` | `"Wurk::Encryption::DecryptionError"` (a literal marker string) |
| `error_message` | `"encryption_error: <real exception class>: <message>"` |
| `failed_at` | now, in epoch ms |
| `args` | **unchanged** — still-encrypted envelope, earlier args plaintext |

Exceptions caught and funnelled into that path: `Wurk::Encryption::Error` (and
its `KeyMissingError` / `DecryptionError` subclasses),
`OpenSSL::Cipher::CipherError` (bad key or tampering — GCM tag mismatch),
`ArgumentError` and `TypeError` (malformed envelope: bad base64, missing `v`),
and `JSON::ParserError`.

Because the payload is preserved verbatim, the recovery for "I rotated too
early" is: restore the old key to the resolver, restart, then retry the job
from the dead set in the dashboard.

**Encryption failures at push time behave differently.** `encrypt` calls
`key_for(active_version)`, so a missing or wrong-sized key raises
`Wurk::Encryption::KeyMissingError` / `Error` **out of `perform_async`**, in
your web request. Nothing is enqueued. Fail your boot or your healthcheck on a
bad key rather than discovering it on the first push.

---

## What the dashboard shows

`Wurk::Encryption.redact_args` replaces the last argument with the literal
string `"<encrypted>"` in every args column the API serves: queue listings,
retries, scheduled, dead, the busy/working table, and search results
(`JobRecord#display_args`).

Two important properties:

- Redaction keys off the **envelope shape** as well as the `encrypt` flag.
  `encrypt: true` is a `sidekiq_options` value and isn't guaranteed to be
  present on every stored record, so envelope detection is the real guard —
  ciphertext cannot leak into the dashboard even if the flag is missing.
- It is **display-only**. The stored payload is untouched, so retrying a
  redacted job replays the real encrypted argument.

Earlier plaintext args stay visible so you can still find "the failing job for
user 4711". Error messages and backtraces are shown plaintext — see the threat
model.

---

## Interactions

| Feature | Works? | Detail |
|---------|--------|--------|
| `perform_async`, `set(...)`, `perform_in/at` | Yes | Normal client chain. |
| `push_bulk` | Yes | The client chain runs per payload inside the bulk loop. |
| Batches (`Wurk::Batch#jobs`) | Yes | Batch jobs are pushed through the same client chain; the batch middleware only stamps `bid`. |
| Retries / dead set | Yes | The retrier re-serializes the **original** job string, so the envelope is preserved across retries — it is never re-encrypted or double-wrapped. |
| Double-encryption | Safe | The client middleware skips an arg that is already an envelope. |
| Empty `args` | Safe | Skipped silently; `perform` raises `ArgumentError` on its own if it cares. |
| Unique jobs (`Wurk::Unique`) | **No** | The default lock digest is `SHA256([class, queue, args])`, and every push gets a fresh random IV — so no two pushes ever collide and the lock never fires. Define `self.sidekiq_unique_context(job)` on the worker to dedup on the plaintext args only if you need both. |
| `Sidekiq::Testing.inline!` / `drain` | **No, by default** | Inline execution runs `Wurk::Testing.server_middleware`, a separate chain that is empty by default — `perform` receives the raw envelope Hash. See below. |
| ActiveJob | Not recommended | An ActiveJob push has exactly one Wurk arg: the whole serialized AJ payload. Encrypting it encrypts the job class, queue metadata, and arguments together, and the dashboard can no longer unwrap it (`display_args` reads `args[0]["arguments"]`, which the envelope doesn't have) — so the row renders empty. Encrypt at the ActiveJob layer instead (see [ActiveJob](active-job.md)). |

To decrypt under `inline!` / `drain`, register the server middleware on the
testing chain:

```ruby
# test/test_helper.rb
Sidekiq::Testing.server_middleware do |chain|
  chain.add(Wurk::Encryption::ServerMiddleware)
end
```

---

## Operational gotchas

- **`encrypt: true` without `enable` is a silent no-op.** The client middleware
  returns early when crypto is disabled, and the argument goes to Redis in
  cleartext. Assert on it at boot:
  `raise "crypto off" unless Sidekiq::Enterprise::Crypto.enabled? || Rails.env.test?`.
- **Enable everywhere, not just on workers.** The client middleware runs in the
  process that *pushes*. A web dyno without the initializer enqueues cleartext
  that a worker will happily execute.
- **Args are `JSON.dump`ed, then `JSON.parse`d.** Symbol keys come back as
  strings; `Time`/`Date`/`BigDecimal`/custom objects come back as whatever
  their JSON form was. This is the same rule as unencrypted Wurk args, but it
  bites harder because you can't eyeball the payload in Redis.
- **Payload size.** Ciphertext plus base64 is ~30% larger. Keep the secret bag
  small — Redis stores whole job payloads in memory.
- **Key files are secrets.** Don't commit them; mount them, or use ENV/KMS. A
  Redis dump plus a leaked key file is the same as no encryption.
- **`Wurk::Encryption.disable!` exists but is a test helper**, not part of the
  Sidekiq surface. Don't call it in production code.
- **No per-argument or whole-payload mode.** Last positional arg only.

---

## Related

- [Migrating from Sidekiq](migrate-from-sidekiq.md) — what carries over on the
  gem swap, and what to drain first.
- [Authentication & authorization](authentication.md) — the dashboard shows
  plaintext leading args and error messages; gate it.
- [ActiveJob](active-job.md) — why AJ payloads want encryption at the AJ layer.
- [Deployment](deployment.md) — where the initializer and key material need to
  be present.
