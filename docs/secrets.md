# Secrets & credentials

The one page for wiring up the secret values a production Wurk deploy needs, in
one place instead of five. It says which values are genuinely **secret** (must
never be committed), which are plain configuration, how to supply each one, and
what happens when two sources set the same thing.

> The per-feature pages remain authoritative for behaviour:
> [configuration.md](configuration.md) (every env var and option),
> [encryption.md](encryption.md) (the key resolver and rotation),
> [authentication.md](authentication.md) (dashboard gating), and
> [sentry.md](sentry.md) (error reporting). This page only collects the
> secret-handling parts and states the trust boundary.

One fact shapes everything below: **the only secret-bearing value Wurk itself
reads from the environment is `REDIS_URL`** (`Configuration#initialize`,
`RedisPool::DEFAULT_URL`). Every other secret — the encryption key, the
dashboard credentials, the Sentry DSN — is resolved by Ruby *you* write in
`config/initializers/wurk.rb`. Wurk never reads an env var for those, so where
they come from, and which source wins, is entirely up to your initializer. That
is the freedom the ENV-name conventions in the other docs (`WURK_CRYPTO_KEY_V1`,
`WURK_USER`, `SENTRY_DSN`, …) are examples of, not names Wurk looks up.

---

## What is secret, and what is just config

| Value | Secret? | Read by | Page |
|---|---|---|---|
| `REDIS_URL` (when it embeds a password, e.g. `redis://:pw@host`) | **Yes** — a password in a URL | Wurk, directly from ENV | [configuration.md](configuration.md#redis-connection-and-pool-sizing) |
| `REDIS_URL` (no auth, e.g. `redis://localhost:6379/0`) | No — plain config | Wurk, directly from ENV | [configuration.md](configuration.md) |
| Argument-encryption key (32 raw bytes) | **Yes** — loss is unrecoverable | Your `enable` resolver block | [encryption.md](encryption.md) |
| Dashboard credentials (Basic-auth user/pass, bearer token) | **Yes** | Your Rack middleware / route gate | [authentication.md](authentication.md) |
| Sentry DSN | **Yes** — a write key | Your `Sentry.init` block | [sentry.md](sentry.md) |
| `WURK_WEB_READ_ONLY` | No — plain config | Wurk, directly from ENV | [authentication.md](authentication.md#4-read-only-mode) |
| `WURK_COUNT`, `WURK_MAXMEM_MB`, queues, concurrency, … | No — plain config | Wurk | [configuration.md](configuration.md#environment-variables) |

"Secret" means: it must never be committed to git, never appear in a log or an
error message, and never be pasted into an issue. Plain config can live in
`config/wurk.yml`, a `Dockerfile`, or a checked-in manifest without harm.

---

## The three ways to supply a secret

### 1. Process environment

The default, and the only mechanism Wurk reads on its own (for `REDIS_URL`). Set
it in your process manager, not in a file under version control:

```bash
export REDIS_URL="rediss://:$(cat /run/secrets/redis_pw)@redis.internal:6380/0"
```

In Kubernetes, source it from a `Secret`, never a `ConfigMap` — exactly as the
[deployment manifest](deployment.md#deployment-manifest) does:

```yaml
env:
  - name: REDIS_URL
    valueFrom:
      secretKeyRef: { name: wurk, key: redis-url }
```

For the values Wurk does not read itself, your initializer reads the env var and
assigns it:

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL") }
end

Sidekiq::Enterprise::Crypto.enable(active_version: 1) do |version|
  Base64.strict_decode64(ENV.fetch("WURK_CRYPTO_KEY_V#{version}"))
end
```

### 2. Rails encrypted credentials

`config/credentials.yml.enc` is encrypted at rest; only `master.key` (or
`RAILS_MASTER_KEY`) opens it, and the `.key` is what you keep out of git.
Because Wurk has no built-in credentials lookup, you wire it in the same
initializer — read the credential and assign it:

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.redis = { url: Rails.application.credentials.redis_url }
end

Sidekiq::Enterprise::Crypto.enable(active_version: 1) do |version|
  Rails.application.credentials.dig(:wurk, :crypto_keys, version)
end
```

```ruby
# config/initializers/sentry.rb — sentry-ruby only
Sentry.init { |c| c.dsn = Rails.application.credentials.sentry_dsn }
```

The encryption resolver must return **32 raw bytes**, not hex or base64 — decode
in the block if you stored it encoded (see
[encryption.md § Key requirements](encryption.md#key-requirements-and-sources)).

### 3. An init file on disk

A file mounted into the process (a Docker/K8s secret mount, a systemd
`LoadCredential`) that is read at boot. This is the shape
[encryption.md](encryption.md#enabling) shows for key material:

```ruby
# config/initializers/wurk.rb
Sidekiq::Enterprise::Crypto.enable(active_version: 1) do |version|
  File.binread("/run/secrets/wurk/secret.#{Rails.env}.#{version}.key")
end
```

The file lives outside the repo (mount it, don't `COPY` it), so a leaked image
layer or a `git clone` never carries the key.

---

## Precedence when more than one source is set

Wurk resolves **only `REDIS_URL`** on its own, and only as the default when your
initializer does not set a URL:

```
config.redis = { url: … } in the initializer   >   ENV["REDIS_URL"]   >   redis://localhost:6379/0
```

This is the general [configuration precedence](configuration.md#precedence) — the
initializer runs last, so Ruby wins. If you set `config.redis[:url]` explicitly,
that value is used and the `REDIS_URL` env var is ignored.

For every other secret there is **no built-in fallback chain** — Wurk never
consults two sources for you. Precedence is whatever the Ruby in your resolver
block expresses. To prefer an env var and fall back to credentials, write it
that way yourself:

```ruby
Sidekiq::Enterprise::Crypto.enable(active_version: 1) do |version|
  ENV.fetch("WURK_CRYPTO_KEY_V#{version}") do
    Rails.application.credentials.dig(:wurk, :crypto_keys, version)
  end
end
```

Whichever branch returns the bytes wins; there is no hidden ordering to reason
about beyond your own code.

---

## Rotating the encryption key

Do not overwrite a key in place. The resolver caches each version per process
for the life of the process, so an edited file is not picked up until a restart,
and dropping a version too early strands every payload still encrypted at it.
The full procedure — including the "deploy the resolver first, keeping the old
`active_version`" step and the retry/dead-set tail you must wait out — is in
[encryption.md § Key rotation](encryption.md#key-rotation). In short:

1. Ship the new key everywhere Wurk runs (workers **and** web dynos — the web
   dynos enqueue).
2. Deploy the resolver that can decrypt the new version, still encrypting with
   the old `active_version`.
3. Bump `active_version` to the new version; old in-flight payloads keep
   decrypting because the resolver still answers for their version.
4. Wait out the tail (retry set up to ~21 days, `dead` up to 6 months by
   default).
5. Drop the old version from the resolver only once no payload still uses it.

There is no escrow: **lose a key and every payload at that version is
unrecoverable.**

---

## Never commit

- The Redis URL when it embeds a password — keep the whole `REDIS_URL` in your
  secret store, not just the host.
- Any encryption key file (`*.key`, the 32 raw bytes) — mount it or resolve it
  from ENV/KMS.
- `config/master.key` / `RAILS_MASTER_KEY` — the one file that decrypts
  `credentials.yml.enc`. (`credentials.yml.enc` itself is safe to commit; the
  key is not.)
- Dashboard credentials — the Basic-auth password or bearer token your
  [auth middleware](authentication.md#2-wurkwebuse--rack-middleware) checks.
- The Sentry DSN — it is a write key; treat it as a secret.

Add the obvious patterns to `.gitignore` (`*.key`, `/config/master.key`,
`.env*`) and keep secrets in your platform's secret store — env vars from a
`Secret`, a mounted file, or Rails encrypted credentials. A Redis dump plus a
leaked key file is the same as no encryption at all
([encryption.md § threat model](encryption.md#threat-model)).

---

## Related

- [Configuration reference](configuration.md) — every env var and option, with
  full precedence and Redis connection options (`username:`, `password:`,
  `ssl_params:`, `rediss://`).
- [Deployment](deployment.md) — where each secret needs to be present, and the
  Kubernetes `secretKeyRef` pattern.
- [Encryption](encryption.md) — the key resolver, key requirements, and rotation.
- [Authentication & authorization](authentication.md) — gating the dashboard and
  where credentials are checked.
- [Sentry](sentry.md) — the DSN and what the integration does (and does not)
  send.
