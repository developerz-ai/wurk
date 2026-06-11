# Sidekiq Enterprise — Public API Surface

Spec target for Wurk. Source: contribsys wiki (`sidekiq/sidekiq`), `Ent-Changes.md`, Mike Perham blog posts, and observed `Sidekiq::Limiter` / `Sidekiq::Enterprise` usage in the wild. Reimplement bit-for-bit unless explicitly diverged in `docs/idea/`.

Coordinate-of-truth: everything below is what a paying Sidekiq Enterprise user can call. `require "sidekiq-ent"` (gem name `sidekiq-ent`) loads everything; `require "sidekiq-ent/web"` loads Web UI extensions.

---

## 0. Top-Level Modules

| Constant                          | Role                                                    |
| --------------------------------- | ------------------------------------------------------- |
| `Sidekiq::Enterprise`             | Feature gate + global config (`unique!`, version)       |
| `Sidekiq::Enterprise::Crypto`     | AES-256-GCM args encryption                             |
| `Sidekiq::Enterprise::Unique`     | Unique-job lock store + introspection                   |
| `Sidekiq::Limiter`                | Rate-limiter constructors + config + exceptions         |
| `Sidekiq::Periodic`               | Cron loops, leader-driven                               |
| `Sidekiq::Periodic::LoopSet`      | Enumerable view of registered periodic jobs             |
| `Sidekiq::Periodic::ConfigTester` | Boot-time validator for cron syntax + worker classes    |
| `Sidekiq::Component#leader?`      | Predicate for leader-election (mixed into server comps) |
| `Sidekiq::History`                | Time-series snapshotter (statsd-shaped emitter)         |

`sidekiqswarm` and `sidekiqctl` are binaries, not Ruby APIs (covered in §7–8).

---

## 1. Rate Limiting — `Sidekiq::Limiter`

Five constructors + one no-op. All return a limiter object exposing
`within_limit(...) { ... }`. Internally each is backed by Lua scripts on
Redis; **no system clock reads inside Lua** — all timing is from `redis-cli
TIME`, so cluster clock skew is irrelevant *inside one Redis*, but **all
Sidekiq hosts must run NTP** to agree on `wait_timeout`.

### 1.1 Constructors

```ruby
Sidekiq::Limiter.concurrent(name, limit,
                            wait_timeout: 5,
                            lock_timeout: 30,
                            policy: :raise,        # :raise | :ignore
                            backoff: nil,
                            ttl: 90 * 24 * 3600)

Sidekiq::Limiter.bucket(name, count, interval,
                        wait_timeout: 5,
                        backoff: nil,
                        ttl: 90 * 24 * 3600,
                        reschedule: 20)

Sidekiq::Limiter.window(name, count, interval,
                        wait_timeout: 5,
                        backoff: nil,
                        ttl: 90 * 24 * 3600,
                        reschedule: 20)

Sidekiq::Limiter.leaky(name, bucket_size, drain,
                       wait_timeout: 5,
                       backoff: nil,
                       ttl: 90 * 24 * 3600)

Sidekiq::Limiter.points(name, initial_points, refill_per_second,
                        backoff: nil,
                        ttl: 90 * 24 * 3600)

Sidekiq::Limiter.unlimited(*_ignored_args, **_ignored_kwargs)
```

### 1.2 Argument tables

**Common**

| Arg           | Type            | Notes                                                                            |
| ------------- | --------------- | -------------------------------------------------------------------------------- |
| `name`        | `String`        | `[a-zA-Z0-9_-]+`; interpolation allowed (`"stripe-#{user_id}"`). Used as Redis key suffix. |
| `wait_timeout`| `Integer` (sec) | Max seconds `within_limit` blocks before `OverLimit`. `0` = immediate fail.      |
| `backoff`     | `Proc`          | `->(limiter, job_hash, exc) { seconds }`. Overrides `Sidekiq::Limiter.configure.backoff`. |
| `ttl`         | `Integer` (sec) | Redis key TTL for limiter metadata. Default 90 days. Minimum: 24h.               |
| `reschedule`  | `Integer`       | Max auto-reschedule attempts on `OverLimit`. `0` disables; default 20.           |

**Per-type**

| Type         | Required positional | `interval` accepts                                | Extra                                                     |
| ------------ | ------------------- | ------------------------------------------------- | --------------------------------------------------------- |
| `concurrent` | `limit:Int`         | —                                                 | `lock_timeout:Int`, `policy: :raise \| :ignore`           |
| `bucket`     | `count, interval`   | `:second :minute :hour :day`                      | Resets at cardinal boundaries (00 of unit).               |
| `window`     | `count, interval`   | `:second :minute :hour :day` **or** raw `Integer` | Sliding from first use.                                   |
| `leaky`      | `bucket_size, drain`| `Integer` sec, or `:second :minute :hour :day`    | Drip = `bucket_size / drain` ops/sec.                     |
| `points`     | `initial, refill`   | —                                                 | `within_limit(estimate:)` required; `handle.points_used`. |

### 1.3 `within_limit` semantics

```ruby
limiter.within_limit { ... }                            # concurrent/bucket/window/leaky
limiter.within_limit(used: 1) { ... }                   # bucket/window — charge N units (since 7.2.1)
limiter.within_limit(estimate: 200) { |handle| ... }    # points
```

Behavior matrix:

| Type         | Acquire                                | On exhaustion                                                   | On block-exit                              |
| ------------ | -------------------------------------- | --------------------------------------------------------------- | ------------------------------------------ |
| `concurrent` | atomic slot in ZSET, score = now+lock_timeout | blocks via Redis stream `XREAD` until slot freed, then `OverLimit` after `wait_timeout` | slot deleted; if `lock_timeout` exceeded → "Reclaimed" metric and another waiter may have entered. |
| `bucket`     | INCR bucket key for current epoch unit | `sleep` until next boundary; `OverLimit` if `wait_timeout` < remaining | nothing (count decays at unit rollover)    |
| `window`     | sliding ZSET trim                      | `sleep(0.5)` loop; `OverLimit` past `wait_timeout`              | nothing                                    |
| `leaky`      | atomic leak-then-add                   | `sleep(wait_timeout)` retrying; `OverLimit` if still full       | nothing                                    |
| `points`     | DECRBY `estimate`                      | `OverLimit` immediately if insufficient                         | `handle.points_used(actual)` adjusts delta |
| `unlimited`  | no-op                                  | never                                                           | no-op                                      |

`policy: :ignore` on `concurrent` causes the block to be **silently skipped** when slot unavailable (no exception, no reschedule). Default is `:raise`.

### 1.4 Exceptions

```ruby
Sidekiq::Limiter::OverLimit < StandardError
  # methods: #limiter, #job
```

`OverLimit` is caught by Sidekiq Enterprise server middleware. Behavior:

1. Increments `job['overrated']` (job-hash counter).
2. Computes backoff via per-limiter `backoff` proc → global `Sidekiq::Limiter.configure.backoff` → default `(300 * job['overrated']) + rand(300) + 1`.
3. Reschedules via `Sidekiq::Client.push` at `Time.now + backoff` to the same queue.
4. If `job['overrated'] >= reschedule` (default 20), the exception is re-raised so the normal retry/dead pipeline takes over.

`points.within_limit(estimate:)` raises `OverLimit` *immediately* (no `sleep`) when bucket empty.

### 1.5 Instance API (introspection)

Added per 7.2.3:

```ruby
limiter.name       #=> String
limiter.type       #=> :concurrent | :bucket | :window | :leaky | :points | :unlimited
limiter.options    #=> Hash
limiter.size       #=> Integer (current usage; type-dependent)
limiter.status     #=> Hash of metric counters
limiter.reset      # clears state
limiter.delete     # removes all Redis keys for this name
```

Concurrent-only metrics keys (`status` hash + Web UI):

```
held, held_time, immediate, waited, wait_time, overages, reclaimed
```

### 1.6 Global config

```ruby
Sidekiq::Limiter.configure do |config|
  config.backoff = ->(limiter, job, exc) { 60 * job['overrated'] }
  config.redis   = { size: 10, url: 'redis://rl:6379/0' } # dedicated pool, optional
  config.errors << MyApp::ExternalRateLimitError          # treated as OverLimit
end
```

Defaults:

- `backoff` → `->(_, j, _) { 300 * j['overrated'] + rand(300) + 1 }`
- `redis` → shares `Sidekiq.redis_pool`
- `errors` → `[Sidekiq::Limiter::OverLimit]`

### 1.7 Redis keys (observed)

Namespace prefix: `lmtr:` (Enterprise convention).

| Key                              | Type   | Purpose                                  |
| -------------------------------- | ------ | ---------------------------------------- |
| `lmtr:{name}`                    | HASH   | Limiter metadata: type, count, interval, ttl, options |
| `lmtr-cs:{name}`                 | ZSET   | concurrent: held slots, score = expiry   |
| `lmtr-cw:{name}`                 | STREAM | concurrent: waiter signalling stream     |
| `lmtr-b:{name}:{epoch}`          | STRING | bucket: counter for current period       |
| `lmtr-w:{name}`                  | ZSET   | window: timestamps within interval       |
| `lmtr-l:{name}`                  | HASH   | leaky: `{level, last_drain_ts}`          |
| `lmtr-p:{name}`                  | HASH   | points: `{points, last_refill_ts}`       |
| `lmtr-stats:{name}`              | HASH   | metric counters (concurrent only)        |
| `lmtr-list`                      | SET    | all limiter names (Web UI listing)       |

All keys carry `EXPIRE = ttl`. 8.0.0 switched fingerprinting from SHA1 → SHA256 (~10% larger encoding).

### 1.8 Testing

```ruby
def test_my_worker
  worker = MyWorker.new
  worker.limiter = Sidekiq::Limiter.unlimited       # bypass entirely
  worker.perform(...)
end
```

Recommended pattern: store the limiter on the worker instance and swap to `.unlimited` in tests.

### 1.9 Non-composability

By design no AND combinator. To enforce "5/min AND 100/hr", configure the tighter limit and rely on the remote API's own response to throttle the looser one. Documented invariant.

---

## 2. Periodic Jobs — `Sidekiq::Periodic`

Pure leader-driven cron. Only the elected leader enqueues; non-leader servers run nothing. No backfill on restart, no DST double-fire after 2.3.1.

### 2.1 Registration DSL

```ruby
Sidekiq.configure_server do |config|
  config.periodic do |mgr|
    mgr.tz = ActiveSupport::TimeZone.new("America/Chicago")   # optional, applies to subsequent calls
    mgr.register("*/5 * * * *", "FooWorker")
    mgr.register("0 4 * * *",   "BarWorker", retry: 2, queue: "low", args: ["nightly"])
    mgr.register("0 * * * *",   "TZWorker",  tz: ActiveSupport::TimeZone.new("Asia/Tokyo"))
  end
end
```

### 2.2 `mgr.register(cron, klass, opts={})`

| Param   | Type                            | Notes                                                     |
| ------- | ------------------------------- | --------------------------------------------------------- |
| `cron`  | `String`                        | 5-field crontab. Minimum frequency = 1 minute.            |
| `klass` | `String`                        | Worker class name as string (not constant — boot order). |
| `opts`  | `Hash`                          | Recognized: `retry`, `queue`, `args`, `tz`.               |

`opts[:args]` is a **static** array evaluated once at boot; passed verbatim into `klass.perform_async(*args)` on every tick. `opts[:tz]` (per-job) does not enter the job payload — used only to compute the next-fire moment.

`mgr.tz=` sets a default TimeZone that subsequent `register` calls inherit. Per-call `tz:` overrides.

ActiveJob support added 7.1.0 (klass may be an ActiveJob subclass name).

### 2.3 LoopSet (introspection)

```ruby
loops = Sidekiq::Periodic::LoopSet.new
loops.each do |lop|
  lop.schedule   #=> "*/5 * * * *"
  lop.klass      #=> "FooWorker"
  lop.lid        #=> "0a4f..."  (loop ID, 16-hex)
  lop.options    #=> { "retry" => 2, "queue" => "low", ... }
  lop.history    #=> [[ts_unix, jid], ...] last N executions
end

loops.size
loops.fetch(lid)
```

### 2.4 Web UI ops (8.0.1+)

- pause / unpause individual loops (writes `paused:1` to loop HASH)
- "Enqueue Now" button (`perform_async` immediately)
- Execution history view

### 2.5 Test helper

```ruby
require "sidekiq-ent/periodic/testing"

PERIODIC_JOBS = ->(mgr) { mgr.register("* * * * *", "Foo") }

ct = Sidekiq::Periodic::ConfigTester.new
ct.verify(&PERIODIC_JOBS)   # raises if klass constant missing or cron invalid
```

### 2.6 Semantics & edge cases

| Concern                  | Behavior                                                                     |
| ------------------------ | ---------------------------------------------------------------------------- |
| Leader churn             | Leader renews every 15s; followers re-check every 60s; on leader death, a follower assumes leadership within ≤60s. Missed ticks during the gap are **not** backfilled. |
| Quiet leader             | A `USR1`-quieted leader **still enqueues** cron jobs — it only stops fetching for itself. Loops stop only on full shutdown. |
| Slow tick                | Pre-1.2.4: silent miss; 1.2.4+: warning logged.                              |
| DST                      | 2.3.1+: leader elects more often around DST boundaries to avoid skipped hour.|
| Duplicates               | Single-leader invariant guarantees one enqueue per (loop, tick). For per-job idempotency combine with §3 Unique Jobs. |

### 2.7 Redis keys

| Key                          | Type | Purpose                                          |
| ---------------------------- | ---- | ------------------------------------------------ |
| `periodic`                   | SET  | All loop IDs                                     |
| `loops:{lid}`                | HASH | `{schedule, klass, options(json), tz, paused}`   |
| `loop-history:{lid}`         | LIST | Recent fire records (capped)                     |

> **Wurk divergence (#15):** periodic enqueue is gated by the *single* cluster
> leader (§6, via `Component#leader?`), not a separate `cron-leader` lock.
> Upstream's per-feature lock flaps under Wurk's cadence (60s tick vs 30s TTL);
> the cluster leader renews every 15s and is the single source of truth for
> "am I leader?" across periodic, metrics rollup, etc.

---

## 3. Unique Jobs — `Sidekiq::Enterprise::Unique`

Best-effort dedup at enqueue time (and optionally during execution). Lock keyed by *digest of (class, queue, args)*.

### 3.1 Enabling

```ruby
# config/initializers/sidekiq.rb
Sidekiq::Enterprise.unique! unless Rails.env.test?
```

This installs the client middleware (lock-on-push) and server middleware (lock-release-on-success/start).

### 3.2 Per-worker options

```ruby
class FooWorker
  include Sidekiq::Job
  sidekiq_options unique_for:   10.minutes,
                  unique_until: :success     # :success (default) | :start
end
```

| Option         | Type                        | Default     | Meaning                                                                                                |
| -------------- | --------------------------- | ----------- | ------------------------------------------------------------------------------------------------------ |
| `unique_for`   | `Integer` / `ActiveSupport::Duration` / `false` | **required** when `unique!` is on | Lock TTL in seconds. `false` disables uniqueness for that worker / call. |
| `unique_until` | `Symbol`                    | `:success`  | `:success` → lock held through retries until job succeeds; `:start` → lock released right before `perform`. |

`unique_for` is **required** — there is no default — to prevent indefinite locks after a process crash. Recommended: keep it short (a few minutes). Long locks are a code smell.

### 3.3 Per-call override

```ruby
FooWorker.set(unique_for: false).perform_async(1, 2, 3)   # skip lock
FooWorker.set(unique_for: 60).perform_async(1, 2, 3)      # 60s override
```

### 3.4 Scheduled jobs

`perform_in(delay, ...)` locks for **`delay + unique_for`** so the lock covers the wait + execution window.

### 3.5 Custom lock context (7.0.3+)

```ruby
class FooWorker
  include Sidekiq::Job
  sidekiq_options unique_for: 5.minutes

  # Reduce or transform args used for digest computation.
  def self.sidekiq_unique_context(job)
    a = job["args"].dup
    a.pop if a.size == 3                       # drop trailing options hash
    [job["class"], job["queue"], a]
  end
end
```

Default context: `[job["class"], job["queue"], job["args"]]`. SHA256 of JSON-dumped context is the lock key (8.0.0+; SHA1 prior).

### 3.6 Introspection

```ruby
Sidekiq::Enterprise::Unique.locked?(queue=nil, klass, args)
  #=> jid (String) holding the lock, or nil
```

### 3.7 Lock semantics

| Event                     | `:success` (default)                                     | `:start`                                                       |
| ------------------------- | -------------------------------------------------------- | -------------------------------------------------------------- |
| Push                      | SETNX lock with `unique_for` TTL                         | same                                                           |
| Push duplicate            | client middleware drops the duplicate (returns `nil` JID; logs "JID X holds lock"). |
| `perform` start           | lock retained                                            | lock DELed before `perform`                                    |
| `perform` raises          | lock retained → next retry can proceed once attempted    | lock already gone → duplicate can be enqueued                  |
| `perform` succeeds        | lock DELed                                               | (already gone)                                                 |
| Process crash             | lock survives until TTL expiry → must be short          | same                                                           |

7.3.2: server-side unique middleware also runs in **client mode** so `perform_inline` honors locks during tests.

### 3.8 Incompatibilities

Unique + Encryption are mutually exclusive — encrypted args produce different ciphertext per push, defeating the digest. Documented.

### 3.9 Redis keys

| Key                  | Type | Purpose                                                         |
| -------------------- | ---- | --------------------------------------------------------------- |
| `unique:{sha256}`    | STR  | Holds owning JID; TTL = `unique_for` (+ `delay` if scheduled).  |

---

## 4. Encryption — `Sidekiq::Enterprise::Crypto`

AES-256-GCM (fallback AES-256-CBC on OpenSSL < 1.0.1) over the **last** argument of `perform`.

### 4.1 Enabling

```ruby
# Initializer
Sidekiq::Enterprise::Crypto.enable(active_version: 1) do |version|
  File.open("./config/crypto/secret.#{Rails.env}.#{version}.key", "rb:ASCII-8BIT").read
end

# Worker
class PrivateJob
  include Sidekiq::Job
  sidekiq_options encrypt: true

  def perform(public_arg, secret_bag)
    # secret_bag has been decrypted in-place by server middleware
  end
end
```

### 4.2 Key generation

```ruby
require "openssl"
File.open("./config/crypto/secret.production.1.key", "w:ASCII-8BIT") do |f|
  f.write(OpenSSL::Cipher.new("aes-256-gcm").random_key)   # 32 bytes
end
```

Key sources: file, `ENV`, KMS — any callback that maps `Integer version → 32-byte binary key`.

### 4.3 Argument shape

- Worker `perform` **must** accept ≥ 2 positional args. Use `nil` as the first if no cleartext payload: `perform(nil, secret_bag)`.
- Only the **last** positional argument is encrypted.
- All preceding args remain cleartext (visible in Web UI, retry payloads, error logs).

### 4.4 On-wire format

In Redis the job's last arg becomes a JSON Hash envelope (not a base64 blob of a
binary envelope — the args array stays valid JSON for inspectors):

```
{ "__wurk_enc__" => true, "v" => active_version, "iv" => b64(iv), "ct" => b64(ciphertext), "tag" => b64(gcm_tag) }
```

The leading `__wurk_enc__ => true` marker is the authoritative envelope
discriminator: detection (`Wurk::Encryption.envelope?`, used by both the server
middleware and the Web UI redactor) keys off it, so a plain user Hash that
happens to carry `v`/`iv`/`ct`/`tag` keys is never mistaken for ciphertext and
fed to the cipher. wurk both writes and reads this format, so it is
self-consistent; it is *not* wire-compatible with real Sidekiq Enterprise's
crypto format (a base64 binary blob), which is a documented divergence — encrypted
payloads do not round-trip Ent↔wurk regardless.

Overhead: ~150 bytes + ~30% size growth from base64.

### 4.5 Key rotation

1. Generate `secret.{env}.{N+1}.key`.
2. Bump `active_version: N+1`.
3. Block must still return keys for **all** in-flight versions (old enqueued jobs decrypt with prior key).
4. Once `retries`, `dead`, and `scheduled` no longer hold v=N payloads, delete the old key.

### 4.6 Exceptions

- Decryption failure (missing version / bad tag) raises `OpenSSL::Cipher::CipherError` from inside server middleware → job goes to retry/dead like any other failure. Cleartext args remain visible for triage.

### 4.7 Web UI

Encrypted payloads stay opaque in the Web UI args column until executed (rendered as `"<encrypted>"`). Error backtraces are plaintext.

### 4.8 Constraints

- **Incompatible with Unique Jobs** (each ciphertext differs).
- **Incompatible with Testing's `Sidekiq::Testing.inline!`** without explicit decryption — see GH issue #4564; server middleware must run for `secret_bag` to be decrypted.

---

## 5. Historical Metrics — `Sidekiq::History`

Periodic snapshotter that emits **statsd-shaped** samples to a user-supplied client. There is no built-in time-series store; persistence is offloaded to Datadog / Prometheus pushgateway / Statsd / InfluxDB. The Enterprise UI consumes the same emitter for its history graphs (8.0+ stores recent points in Redis).

### 5.1 Config DSL

```ruby
Sidekiq.configure_server do |config|
  config.retain_history(30)                            # seconds between snapshots
  # or with a custom collector block:
  config.retain_history(30) do |s|
    Sidekiq::Queue.all.each do |q|
      s.batch do |b|
        b.gauge("sidekiq.queue.latency", q.latency, tags: ["queue:#{q.name}"])
        b.gauge("sidekiq.queue.size",    q.size,    tags: ["queue:#{q.name}"])
      end
    end
  end
end
```

`s` quacks like `Datadog::Statsd` (or `dogstatsd-ruby`): `gauge`, `count`, `histogram`, `batch`. If no block is given, the **default** emitter publishes the metrics in §5.2.

### 5.2 Default metrics

| Name                    | Type   | Tags                  | Source                              |
| ----------------------- | ------ | --------------------- | ----------------------------------- |
| `sidekiq.processed`     | gauge  | —                     | `Sidekiq::Stats#processed`          |
| `sidekiq.failures`      | gauge  | —                     | `Sidekiq::Stats#failed`             |
| `sidekiq.enqueued`      | gauge  | —                     | total Q size                        |
| `sidekiq.retries`       | gauge  | —                     | retry set size                      |
| `sidekiq.dead`          | gauge  | —                     | dead set size                       |
| `sidekiq.scheduled`     | gauge  | —                     | scheduled set size                  |
| `sidekiq.busy`          | gauge  | —                     | active job count                    |
| `sidekiq.queue.size`    | gauge  | `queue:<name>`        | per-queue depth                     |
| `sidekiq.queue.latency` | gauge  | `queue:<name>` (default queue only pre-2.1.0) | head-of-line wait |

2.1.0 migrated from `sidekiq.queue.<name>.size` interpolation → tag-based.

### 5.3 Web UI consumption

`require "sidekiq-ent/web"` enables the Historical tab. Last N snapshots are kept in a capped Redis stream (`history:metrics`) and rendered as a graph; long-term retention requires an external TSDB.

---

## 6. Leader Election

Lightweight single-leader-per-cluster. Not Raft. Lock in Redis, periodically renewed; *no fencing tokens exposed to the user* (Enterprise documents this as best-effort coordination, not strict mutex).

### 6.1 API

```ruby
class MyService
  include Sidekiq::Component                   # provides logger, redis, safe_thread, leader?

  def initialize(config); @config = config; @done = false; end

  def start
    @thread = safe_thread("myservice", &method(:process))
  end

  def stop = @done = true

  private

  def process
    until @done
      if leader?
        logger.info "ping"
      end
      sleep 30
    end
  end
end
```

`leader?` is the **only public predicate** — returns `true` iff the current process holds the leader lock at call time. There is no `on_leader` callback in the public API beyond the `:leader` lifecycle event (§6.3).

### 6.2 Mechanics

| Param                | Value                                                              |
| -------------------- | ------------------------------------------------------------------ |
| Leader renew         | every 15s                                                          |
| Follower check       | every 60s                                                          |
| Lock TTL             | ~30s (2× renew)                                                    |
| Step-down on quiesce | leader steps down immediately on USR1 quiet (since 2.2.3 — invalid leaders self-evict). Periodic still enqueues. |
| Opt out              | `SIDEKIQ_LEADER=false` env on a process → never campaigns for leader. Useful for hot-standby pools. |

### 6.3 Events

```ruby
Sidekiq.configure_server do |config|
  config.on(:leader) do
    # fired when this process gains leadership (since 0.7.7)
  end
end
```

No corresponding `:follower` event; check `leader?` from within long-running threads.

### 6.4 Redis keys

| Key       | Type | Purpose                                       |
| --------- | ---- | --------------------------------------------- |
| `leader`  | STR  | Holds `<pid>@<hostname>:<process_nonce>`, EX=30 |

### 6.5 Fencing

**None exposed.** Operations that absolutely must not double-execute should additionally use Unique Jobs (§3) or external idempotency keys. Documented behavior, not a bug.

---

## 7. Multi-Process — `sidekiqswarm`

Binary, not Ruby API. Forks N children from one preloaded parent.

### 7.1 Invocation

```bash
bundle exec sidekiqswarm -e production -r ./config/environment.rb
```

Flags **disallowed** (vs. plain `sidekiq`): `-d` (daemonize), `-L` (logfile), `-P` (pidfile). All other Sidekiq CLI args are forwarded to each child.

### 7.2 Environment variables

| Var                          | Default        | Effect                                                                                  |
| ---------------------------- | -------------- | --------------------------------------------------------------------------------------- |
| `SIDEKIQ_COUNT`              | CPU count      | Number of children. Fractional supported (8.0.2+): `0.5` × CPU.                         |
| `SIDEKIQ_MAXMEM_MB`          | disabled       | RSS threshold; child exceeding it gets `USR2` (graceful) then is replaced.              |
| `SIDEKIQ_PRELOAD`            | `default`      | Comma-separated Bundler groups to load in parent. Empty (`SIDEKIQ_PRELOAD=`) disables preload. |
| `SIDEKIQ_PRELOAD_APP`        | `0`            | `1` → `require` whole app in parent before fork (4.6.0+). Saves 20–30% RSS via CoW.     |
| `SIDEKIQ_LEADER`             | `true`         | `false` makes process ineligible to lead.                                               |
| `SIDEKIQ_FORK_PER_PROCESS_HOOK` | n/a         | Documented hook name only; actual API is the `on(:fork)` callback (§7.4).               |

### 7.3 Process model

```
sidekiqswarm (parent)
├── child #0   (own Redis pool, own threads, own fetcher)
├── child #1
└── ...
```

- Parent does **not** fetch jobs.
- Parent forks after `Bundler.require` (and after `require app_root` if `SIDEKIQ_PRELOAD_APP=1`).
- Each child establishes its own Redis connection pool post-fork.
- 7.3.3: `Process.warmup` called before fork; health checks **disabled** in swarm parent (only children expose them).

### 7.4 Fork callback

```ruby
Sidekiq.configure_server do |config|
  config.on(:fork) do
    # Runs in each child *after* fork. Reopen sockets, restart threads,
    # reconnect to non-fork-safe libraries.
  end
end
```

`connection_pool` ≥ 2.4 and ActiveRecord ≥ 5.2 are fork-safe.

### 7.5 Memory-based auto-restart

When `SIDEKIQ_MAXMEM_MB` is set, parent polls each child's RSS (`get_process_mem` gem since 8.0.2). On exceeding threshold:

1. Parent sends `USR2` to that child.
2. Child enters "quiet" → stops fetching, finishes in-flight jobs.
3. Child exits cleanly.
4. Parent forks a replacement.

### 7.6 Signals (parent → children)

| Signal | Effect                                                                  |
| ------ | ----------------------------------------------------------------------- |
| `USR2` | Per-child graceful restart (memory trigger or manual).                  |
| `TERM` | Graceful shutdown of swarm: parent forwards `TERM` to all children, then exits when all have exited. Parent does **not** spawn replacements after `TERM`. |
| `TSTP` | Forward to children — "quiet" all of them (stop fetching, keep running). |
| `USR1` | Forwarded to children (same as `TSTP` in modern Sidekiq).               |

`TTIN` is **not** intercepted by the parent; if needed, send directly to a child PID.

### 7.7 Systemd

```ini
[Service]
Type=notify
Environment=SIDEKIQ_COUNT=4
Environment=SIDEKIQ_MAXMEM_MB=1500
ExecStart=/usr/local/bin/bundle exec sidekiqswarm -e production
ExecReload=/usr/local/bin/bundle exec einhornsh --execute upgrade
TimeoutStartSec=60
```

`Type=notify` supported since 2.1.1 (boot timeout extended to 60s).

---

## 8. Rolling Restarts

No bespoke daemon — Enterprise documents using **einhorn** as the supervisor for true zero-drop restarts. Ent ≥ 1.7.0 is required.

### 8.1 Invocation

```bash
einhorn -m10 -- bundle exec sidekiqswarm -e production
```

`-m10` = "manual" mode; after 10s of the new process being healthy, signal old to start quieting.

### 8.2 Triggering a rolling restart

```bash
einhornsh --execute upgrade            # spawn new, signal old TSTP, wait, then TERM
systemctl reload sidekiq               # if ExecReload is wired to einhornsh upgrade
```

### 8.3 Zero-drop semantics

1. Einhorn forks a fresh `sidekiqswarm` (new code).
2. New parent boots, forks children → they start fetching.
3. Old parent's children receive `TSTP`: they finish in-flight jobs but stop fetching.
4. When the old children are idle, einhorn `TERM`s them; old parent exits.
5. **No time limit** by default — long-running jobs delay full transition (acceptable trade-off).

### 8.4 sidekiqctl (open-source, used by Ent for non-rolling control)

| Command                         | Signal sent  | Effect                                                                  |
| ------------------------------- | ------------ | ----------------------------------------------------------------------- |
| `sidekiqctl quiet <pidfile>`    | `TSTP`       | Stop fetching, finish current.                                          |
| `sidekiqctl stop <pidfile> [t]` | `TERM`, then `KILL` after `t` (default 60s) | Graceful, then forced.                                |

Note: `SIGUSR1` historically aliased to "quiet" (still accepted) but `TSTP` is canonical.

### 8.5 Manually quieted processes

A process quieted by hand (not via einhorn upgrade) does **not** self-exit — operator must `TERM` it. Einhorn-driven upgrades handle this end-to-end.

---

## 9. Web UI Additions — `require "sidekiq-ent/web"`

Mounted exactly like the open-source `Sidekiq::Web`:

```ruby
# config/routes.rb
require "sidekiq/web"
require "sidekiq-ent/web"

Sidekiq::Web.set :sessions, false
mount Sidekiq::Web => "/sidekiq"
```

### 9.1 Added tabs

| Tab          | Source feature       | Capabilities                                                            |
| ------------ | -------------------- | ----------------------------------------------------------------------- |
| **Limits**   | §1 Rate Limiters     | List all limiters, filter by name (2.2.0+), show metrics + reset.       |
| **Periodic** | §2 Periodic Jobs     | List loops, pause/unpause, enqueue-now, view history (8.0.1+). Pre-7.0.0 named "Cron". |
| **Historical** | §5 Historical Metrics | Per-queue and global gauges over recent window.                       |

### 9.2 Authorization hook (1.5.0+)

```ruby
require "sidekiq-ent/web"

Sidekiq::Web.configure do |config|
  config.authorization do |env, method, path|
    user = env["warden"].user || env[:clearance].current_user
    case method
    when "GET"   then user&.admin? || user&.support?
    when "POST", "DELETE", "PUT" then user&.admin?
    end
  end
end
```

Block returns truthy → request proceeds; falsey → `403`. Integrates with Devise (Warden), Clearance, or any Rack-auth setup via `env`.

### 9.3 RBAC

No first-class roles model; authorize block is the single extension point. Examples in wiki cover "admin-only writes, support-read-only".

---

## 10. Enterprise — Top-Level Module

```ruby
Sidekiq::Enterprise::VERSION              #=> "8.x.y"
Sidekiq::Enterprise.unique!               # install unique-jobs middleware
Sidekiq::Enterprise::Crypto.enable(active_version:) { |v| key_bytes }
```

There is no monolithic `Sidekiq::Enterprise.configure` — each subsystem has its own DSL (`Sidekiq::Limiter.configure`, `Sidekiq.configure_server { |c| c.periodic { ... }; c.retain_history(...) }`, `Crypto.enable`).

---

## 11. Version Map of Notable API Additions

| Version | API change                                                                                       |
| ------- | ------------------------------------------------------------------------------------------------ |
| 0.7.7   | `:leader` lifecycle event.                                                                       |
| 1.1.0   | Historical queue metrics subsystem.                                                              |
| 1.2.0   | `sidekiqswarm` introduced.                                                                       |
| 1.2.1   | `SIDEKIQ_MAXMEM_MB` memory-based child restart.                                                  |
| 1.2.4   | Periodic missed-tick warning.                                                                    |
| 1.3.0   | Encryption beta (`encrypt: true`, last-arg).                                                     |
| 1.3.2   | Crypto upgraded to AES-256-GCM.                                                                  |
| 1.5.0   | Web UI custom authorization block.                                                               |
| 1.6.0   | Unique Jobs `unique_until: :start`.                                                              |
| 1.7.0   | `Sidekiq::Limiter.unlimited`; Rolling Restarts via einhorn.                                      |
| 1.8.0   | Default-queue latency gauge.                                                                     |
| 2.1.0   | Tag-based historical metrics (replaces interpolated names).                                      |
| 2.1.1   | sidekiqswarm + systemd `Type=notify`; boot timeout 60s.                                          |
| 2.1.2   | Unique Jobs support in ActiveJob.                                                                |
| 2.2.0   | Leaky-bucket limiter; per-limiter `reschedule:`; Limits UI filter.                               |
| 2.2.1   | Per-job timezone (`tz:`) on periodic.                                                            |
| 2.2.3   | Invalid leaders immediately step down.                                                           |
| 2.3.1   | Leaders elect more often; DST-aware periodic.                                                    |
| 4.6.0   | `SIDEKIQ_PRELOAD_APP=1` whole-app preload.                                                       |
| 7.0.0   | "Cron" tab renamed "Periodic"; bucket history graph removed.                                     |
| 7.0.3   | `sidekiq_unique_context` user-defined unique digest context.                                     |
| 7.0.4   | Unique middleware logs JID holding lock on duplicate push.                                       |
| 7.1.0   | Points-based limiter (GraphQL); ActiveJob for periodic.                                          |
| 7.1.2   | `config.health_check()` for K8s liveness.                                                        |
| 7.2.0   | Health check via YAML config + bind address.                                                     |
| 7.2.1   | `within_limit(used: 1)` for bucket/window.                                                       |
| 7.2.3   | Limiter `attr_readers`; clustered Redis clients on limiters.                                     |
| 7.3.0   | Rate limiting Redis Cluster support.                                                             |
| 7.3.2   | Unique middleware runs in client mode (supports `perform_inline`).                               |
| 7.3.3   | `Process.warmup` pre-fork; swarm health checks disabled in parent.                               |
| 8.0.0   | SHA1 → SHA256 for unique and limiter fingerprints; +10% Redis space.                             |
| 8.0.1   | Periodic UI: pause / unpause / enqueue-now.                                                      |
| 8.0.2   | `get_process_mem` for swarm RSS tracking; fractional `SIDEKIQ_COUNT`.                            |
| 8.1.0   | Periodic UI styling.                                                                             |

---

## 12. Implementation Checklist for Wurk

To claim "Enterprise drop-in", Wurk must expose, identically signed and Redis-key-compatible where users would observe:

- [ ] `Sidekiq::Limiter.{concurrent, bucket, window, leaky, points, unlimited}` constructors with the kwargs of §1.1
- [ ] `Sidekiq::Limiter::OverLimit` exception and `job["overrated"]` middleware contract
- [ ] `Sidekiq::Limiter.configure` (`backoff`, `redis`, `errors`)
- [ ] `Sidekiq.configure_server { |c| c.periodic { |mgr| mgr.register(...); mgr.tz = ... } }`
- [ ] `Sidekiq::Periodic::LoopSet`, `Sidekiq::Periodic::ConfigTester`
- [ ] `Sidekiq::Enterprise.unique!`; `sidekiq_options unique_for:, unique_until:`; `sidekiq_unique_context`
- [ ] `Sidekiq::Enterprise::Unique.locked?`
- [ ] `Sidekiq::Enterprise::Crypto.enable(active_version:) { |v| key }`; `sidekiq_options encrypt: true`; AES-256-GCM envelope on last arg only
- [ ] `config.retain_history(seconds_or_block)` statsd emitter
- [ ] `Sidekiq::Component#leader?`; `:leader` event; `SIDEKIQ_LEADER=false` opt-out
- [ ] `sidekiqswarm` binary honoring `SIDEKIQ_COUNT`, `SIDEKIQ_MAXMEM_MB`, `SIDEKIQ_PRELOAD`, `SIDEKIQ_PRELOAD_APP`; `on(:fork)` hook
- [ ] Rolling-restart compatibility with einhorn (or document Wurk-native equivalent in `docs/idea/`)
- [ ] `require "sidekiq-ent/web"` → Limits, Periodic, Historical tabs + authorization block
- [ ] Same Redis key prefixes (`lmtr:`, `loops:`, `periodic`, `unique:`, `leader`, `history:metrics`) for migration parity

End of public API surface.
