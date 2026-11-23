# Unique jobs

Wurk ships native unique jobs — the Sidekiq Enterprise feature, free and in the
same gem. Enqueueing a job takes a Redis lock keyed by a digest of the job; a
second push of the same job while that lock is held is **dropped** instead of
enqueued.

This is a **best-effort dedup at enqueue time**, not a distributed mutex. Read
[§ What it does not guarantee](#7-what-it-does-not-guarantee) before you rely on
it for correctness.

Everything here is Sidekiq-compatible: `Sidekiq::Enterprise.unique!`,
`sidekiq_options unique_for:`, `sidekiq_unique_context`, and
`Sidekiq::Enterprise::Unique.locked?` are the Enterprise names, and the
implementation lives under `Wurk::Unique`. An existing Enterprise initializer
keeps working on the one-line gem swap, and the Redis key layout
(`unique:<sha256>`) is unchanged, so locks written by Sidekiq Enterprise are
honored by Wurk and vice versa.

> **Coming from the `sidekiq-unique-jobs` gem?** Its `lock:` DSL is a different
> API, and Wurk ships that one natively too, on the gem's own Redis keys: drop the
> gem from the Gemfile and change nothing else. See
> [§13](#13-migrating-from-sidekiq-unique-jobs). §§1–12 are the Enterprise API.

---

## 1. Enable it

Uniqueness is **off** until you turn it on. The client and server middleware
are only installed by `unique!`, so `sidekiq_options unique_for:` on a worker
is a silent no-op without this call:

```ruby
# config/initializers/wurk.rb
Sidekiq::Enterprise.unique!
```

- Installs the client middleware (lock on push), the server middleware (release
  on success/start), and a death handler (release on automatic death).
- Idempotent — calling it twice does not double-register anything.
- Global, process-wide. `Sidekiq::Enterprise.unique?` reports the flag.
- Call it at boot, from an initializer, in **every** process that enqueues and
  every process that runs jobs. A web process without it will happily push
  duplicates.

---

## 2. Declare uniqueness per worker

```ruby
# app/jobs/charge_job.rb
class ChargeJob
  include Sidekiq::Job
  sidekiq_options unique_for: 10.minutes, unique_until: :success

  def perform(account_id, cents) = Billing.charge!(account_id, cents)
end
```

| Option | Type | Default | Meaning |
|---|---|---|---|
| `unique_for` | `Integer` seconds, `ActiveSupport::Duration`, any `Numeric`, or `false` | none — no lock | Lock TTL in seconds. Floats are truncated. `false` or absent disables uniqueness for that push. |
| `unique_until` | `:success` or `:start` | `:success` | When the lock is released. Anything else falls back to `:success`. |

There is **no default TTL**. A worker with no `unique_for` is never deduped,
even with `unique!` on — the option is what opts a worker in. Keep the TTL
short (minutes): after a hard process kill the lock survives until it expires,
and until then that job cannot be enqueued again.

### Per-call override

`set` merges over the class-level `sidekiq_options`, so both the TTL and the
opt-out are per-call:

```ruby
ChargeJob.set(unique_for: false).perform_async(1, 2_500)  # skip the lock entirely
ChargeJob.set(unique_for: 60).perform_async(1, 2_500)     # 60s instead of 10 minutes
```

---

## 3. What happens on a duplicate push

The client middleware does `SET unique:<digest> <jid> NX EX <ttl>`. If the key
already exists and is held by a **different** JID, the push is dropped:

- The job is **never written to Redis** — no queue entry, no schedule entry, no
  metric, no `enqueued` event.
- `perform_async` / `perform_in` return **`nil`** instead of a JID. Code that
  stores the returned JID must handle `nil`.
- `perform_bulk` / `Sidekiq::Client.push_bulk` return an array with a `nil` in
  the position of every dropped job; surviving jobs keep their JIDs.
- One line is logged at `info`:
  `Wurk::Unique: duplicate ChargeJob dropped (jid=… blocked by jid=…)`.
- Nothing raises. A dropped duplicate is normal operation, not an error.

Two pushes are **not** duplicates when the JID already holding the lock is the
job's own JID — that is a re-push of the same job (schedule or retry
promotion), and it proceeds.

---

## 4. When the lock is released

| Event | `unique_until: :success` (default) | `unique_until: :start` |
|---|---|---|
| Push | lock acquired with the TTL | same |
| Duplicate push | dropped, `nil` JID | dropped, `nil` JID |
| `perform` about to start | lock retained | **lock released** before `perform` runs |
| `perform` raises | lock retained → the retry can run; duplicates still blocked | already released → a duplicate can be enqueued mid-run |
| `perform` succeeds | **lock released** | already released |
| Retries exhausted / `retry: false` (automatic death) | lock released by the death handler | already released |
| Manual kill from the dashboard or `RetrySet#kill` | **lock retained** until TTL expiry | already released |
| Process crash (SIGKILL, OOM) | lock retained until TTL expiry | depends on whether `perform` had started |

Every release is an atomic compare-and-delete in Lua: the key is deleted only
if it still holds *this* job's JID. A long-overdue retry can therefore never
release a fresh lock taken by a later enqueue after the original TTL expired.

The manual-kill row is deliberate Enterprise parity — a human killing a job
keeps the slot held, so an automated re-enqueue can't immediately reintroduce
the job the operator just removed. Delete the key yourself if you want it back
sooner ([§ 8](#8-inspecting-and-clearing-locks)).

If Redis is unreachable when the server middleware tries to release, the
failure is logged at `warn` (`Wurk::Unique release failed: …`) and the job
still completes; the lock then expires on its TTL.

---

## 5. How the lock key is derived

```
unique:<SHA256 hexdigest of JSON.dump([job["class"], job["queue"], job["args"]])>
```

A single Redis STRING holding the owning JID, with `EX <ttl>`. Consequences of
that triple:

- **Queue is part of the key.** The same job pushed to `default` and to
  `critical` are two different locks.
- **Args are compared after JSON round-tripping**, exactly as they are stored.
  `perform_async(1)` and `perform_async("1")` are different jobs.
- **Argument order matters**, and so does every element — a trailing options
  hash with a timestamp in it defeats dedup entirely.

### Customizing the digest — `sidekiq_unique_context`

Define a class method on the worker returning any JSON-serializable value; it
replaces the whole `[class, queue, args]` triple:

```ruby
# app/jobs/sync_job.rb
class SyncJob
  include Sidekiq::Job
  sidekiq_options unique_for: 5.minutes

  # Dedup on the account id only — ignore the trailing options hash.
  def self.sidekiq_unique_context(job)
    ["SyncJob", job["queue"], [job["args"].first]]
  end

  def perform(account_id, opts = {}) = Sync.run(account_id, **opts.symbolize_keys)
end
```

- The receiver is the class named by `job["class"]`, resolved from the payload.
  If that constant isn't loaded in the pushing process, the hook is skipped and
  the default triple is used — so an enqueue-only process that doesn't load
  your job classes will compute a *different* key than the worker process.
  Make sure both sides load the class.
- Return whatever identity you want, but return it consistently: the same value
  must come back for the same logical job on both push and release, or the
  server middleware will fail to find the key it should delete.
- Dropping the queue from the context makes the lock queue-independent; keep it
  in if you rely on per-queue locks.

---

## 6. Scheduled jobs, retries, and batches

**Scheduled jobs.** `perform_in(delay, …)` extends the TTL to
`unique_for + delay` (rounded up), so the lock spans the wait *and* the
execution window. An `at` in the past uses the base TTL unchanged. When the
scheduler promotes the job from the `schedule` ZSET to its queue, the client
chain runs again — the lock is still held by that job's own JID, so promotion
is recognized as a re-push and the job is not lost.

**Retries.** Same mechanism: a `retry` ZSET entry promoted back to its queue
re-enters the client chain holding its own lock, and proceeds. With
`unique_until: :success` the lock is deliberately held across the whole retry
chain — that is the point of the mode — so the retry window must fit inside
`unique_for` or a duplicate becomes enqueueable mid-retry.

**Batches.** Batch jobs go through the same client middleware, and the batch
counters are incremented by the push that the middleware halts. A deduped job
therefore never joins the batch at all: totals and pending counts stay
consistent, and the batch's callbacks still fire when the jobs that *were*
added finish. Be aware that `Batch#jobs` returning fewer jobs than you pushed
is the expected outcome, not a bug — check the return values if you need to
know.

---

## 7. What it does not guarantee

- **Not exactly-once execution.** The lock is taken at push time. Anything that
  bypasses the client chain (a raw `LPUSH`, a payload already sitting in Redis
  from before you enabled `unique!`) is not deduped.
- **Not mutual exclusion at runtime.** Two copies of a job can run
  concurrently: with `:start` the lock is gone before `perform`; with `:success`
  a duplicate becomes enqueueable the moment the TTL expires, even mid-run. If
  you need "only one running at a time", use a `Sidekiq::Limiter.concurrent`
  limiter inside `perform`, or make the job idempotent.
- **Not durable past the TTL.** A crashed process leaves the lock behind; it
  disappears when `unique_for` elapses and never before.
- **Not a queue-wide guarantee.** Locks are per digest, and the digest includes
  the queue by default.

---

## 8. Inspecting and clearing locks

```ruby
Sidekiq::Enterprise::Unique.locked?("default", "ChargeJob", [1, 2_500])
#=> "9a1f…"  the JID holding the lock, or nil if free

Sidekiq::Enterprise::Unique.locked?("ChargeJob", [1, 2_500])
# two-arg form: assumes the default queue from Wurk.default_job_options
```

The probe routes through the same derivation as the push path, so it honors
`sidekiq_unique_context` and the ActiveJob narrowing below.
`Wurk::Unique.lock_key(klass, queue, args)` stays available if you want the
verbatim triple digest without any context hook applied.

There is no built-in "unlock" API and **no dashboard view of unique locks** —
the dashboard shows queues, retries, and dead jobs, not lock keys. To clear a
lock manually, delete the key:

```ruby
key = Wurk::Unique.lock_key("ChargeJob", "default", [1, 2_500])
Wurk.redis { |conn| conn.call("DEL", key) }
```

`redis-cli --scan --pattern 'unique:*'` lists every live lock, but the keys are
opaque digests — you can count them and check TTLs, not reverse them into job
names.

---

## 9. Encryption is incompatible

**Do not combine `encrypt: true` with `unique_for:` on the same worker.**
Encryption rewrites the last argument into fresh AES-256-GCM ciphertext on
every push (new IV each time), so no two pushes of the "same" job ever produce
the same args — and therefore never the same digest. Dedup silently stops
working.

Wurk **enforces this**: pushing a worker that sets both `unique_for:` and
`encrypt: true` while encryption is enabled raises
`Wurk::Unique::ConfigurationError` naming the worker and both options. The
check runs per push in the client middleware, so it fires the same way in
either initializer order.

This is stricter than Sidekiq Enterprise, which documents the incompatibility
but lets the silent mis-dedup through. If you need both, encrypt a payload
stored elsewhere and pass an opaque, stable id as the job argument.

---

## 10. Testing

- **`Sidekiq::Testing.fake!`** — the client middleware still runs, so pushes are
  deduped and the fake store reflects that. Locks are taken in real Redis.
- **`Sidekiq::Testing.inline!`** — jobs execute through
  `Sidekiq::Testing.server_middleware`, which is **empty by default** and does
  *not* inherit the globally registered server middleware. The enqueue-time
  lock is therefore taken and never released until its TTL expires. Register it
  explicitly if inline tests need release semantics:

  ```ruby
  Sidekiq::Testing.server_middleware { |c| c.add(Wurk::Unique::ServerMiddleware) }
  ```

- **`perform_inline` / `perform_sync`** run the real client and server chains
  (matching Sidekiq 8), so a lock is taken and released around the run.
- Tests that enqueue the same job repeatedly will see `nil` JIDs unless each
  test clears the `unique:*` keys or uses distinct args. The usual fix is to
  skip activation in the test env: `Sidekiq::Enterprise.unique! unless Rails.env.test?`.

---

## 11. ActiveJob

`sidekiq_options unique_for:` works on an ActiveJob class — the adapter merges
the wrapped class's options into the payload, and Wurk narrows the digest for
you. An ActiveJob payload's args are `[job.serialize]`, a hash carrying a fresh
`job_id` and `enqueued_at` on every push; digesting it verbatim would never
match. So when the wire class is an ActiveJob wrapper and the single arg
carries `job_class` + `arguments`, the context becomes:

```ruby
[job["class"], job["queue"], data["job_class"], data["arguments"]]
```

Per-push fields are dropped: `job_id`, `provider_job_id`, `enqueued_at`,
`scheduled_at`, `executions`, `exception_executions`, `priority`, `locale`,
`timezone`. Retry counters are excluded deliberately — keeping them would make
a retry re-push compute a different key and miss its own lock. The wrapper
class name stays in the context so an ActiveJob `Foo` and a plain worker `Foo`
with the same args can't collide.

Matching is by wire class name, so it works in an enqueue-only process that has
never loaded the job class. An app that subclasses the wrapper under its own
name won't be matched — use the hook below for that.

To override the default, define the context hook on the wrapper class, which is
what `job["class"]` names on the wire:

```ruby
# config/initializers/wurk.rb
class Sidekiq::ActiveJob::Wrapper
  def self.sidekiq_unique_context(job)
    data = job["args"].first
    [data["job_class"], job["queue"], data["arguments"]]
  end
end
```

That is global to every ActiveJob in the app. If only some of your jobs need
uniqueness, prefer a plain `include Sidekiq::Job` worker for those.

---

## 12. Collapsing bursts and rate ceilings — `collapse:`

Three Wurk extras answer "this was enqueued more often than it needs to run",
each keeping a different job:

| Policy | Keeps | Use it when |
|---|---|---|
| `unique_for:` (this page) | The **first** push; rejects duplicates until the lock clears | You want exactly one in flight, and later pushes carry nothing new |
| `collapse: { policy: :debounce, … }` | The **last** push's payload, fired once the burst goes quiet | Fifty edits in a minute should produce one rebuild, with the *latest* state |
| `collapse: { policy: :throttle, … }` | The **first** push per fixed time slot; every extra in that slot is dropped | Poll an API at most once a minute, however many events ask for it |

Both `collapse:` policies are separate from `unique_for:` on purpose — a lock
drops the very re-enqueue debounce needs to extend a burst — and a
worker declares at most one of the two; declaring both raises
`Wurk::Collapse::ConfigurationError` where the class is defined.

```ruby
class ReindexJob
  include Wurk::Job
  sidekiq_options collapse: { policy: :debounce, wait: 5, max_wait: 60 }

  def perform(record_id) = Record.find(record_id).reindex!
end

class PollJob
  include Wurk::Job
  sidekiq_options collapse: { policy: :throttle, slot: 60 }

  def perform(feed_id) = Feed.find(feed_id).poll!
end
```

- **`debounce:`** — `wait:` seconds of quiet before the collapsed job fires;
  every push inside the window replaces the pending payload and restarts the
  countdown. `max_wait:` (optional) caps how long a continuously-refreshed
  burst can be held off, so a feed that never goes quiet still eventually
  runs. The collapsed job lands in the ordinary `schedule` ZSET — the
  dashboard, `Wurk::ScheduledSet`, and a stock Sidekiq poller all see it as
  any other scheduled job.
- **`throttle:`** — `slot:` seconds, aligned to the Unix epoch (not to first
  use), so every producer means the same slot by "this minute". Only the
  winner is enqueued; nothing else is stored. `slot:` must be a whole number
  of seconds.
- Both policies share `Wurk::Unique`'s identity digest (`[class, queue,
  args]`), so a class that narrows its key with `sidekiq_unique_context`
  narrows its collapse identity the same way — one hook covers uniqueness,
  debounce, and throttle.
- Both return **nil** from the enqueue call when a push is collapsed, same as
  a dropped `unique_for:` push. `Wurk::Debounce.schedule` / `Wurk::Throttle.admit`
  are the lower-level entry points if you need the detail nil hides (which jid
  currently owns the slot, whether this push replaced a pending sibling).
- `push_bulk` rejects a `collapse:`-declared class outright rather than
  deciding item-by-item — folding per-item collapse decisions into the bulk
  Lua path costs one round trip per item instead of one for the whole batch.
  Measured on a 1,000-job batch: **1,000 round trips and ~6,000 Redis
  commands** per-item, against **1 round trip and 2 commands** to reject. The
  wall-clock gap is far smaller than that 1,000× round-trip ratio on loopback
  Redis — round trips are cheap there — but it grows with every millisecond of
  network latency between you and Redis, which is the case the bulk path exists
  for. Push those jobs individually.
- Neither policy has a `sidekiq-unique-jobs` equivalent; there is nothing to
  migrate in [§13](#13-migrating-from-sidekiq-unique-jobs) beyond `unique_for:`
  itself.

---

## 13. Migrating from sidekiq-unique-jobs

**Drop the gem; change no code.** Wurk carries sidekiq-unique-jobs 8.x natively
(`Wurk::UniqueJobs`): the `lock:` DSL, every option, the global config, the
middleware and the classes apps call. With the gem gone from the bundle,
`SidekiqUniqueJobs` and `require "sidekiq-unique-jobs"` / `"sidekiq_unique_jobs"`
resolve to it, so the gem's usual initializer runs unchanged:

```ruby
# config/initializers/sidekiq.rb, exactly as written for the gem
Sidekiq.configure_server do |config|
  config.client_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Client }
  config.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
  SidekiqUniqueJobs::Server.configure(config)
end

Sidekiq.configure_client do |config|
  config.client_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Client }
end

SidekiqUniqueJobs.configure do |config|
  config.lock_ttl = 2.hours.to_i
  config.reaper = :ruby
end
```

As with the gem, nothing locks until that middleware is in the chain; a boot WARN
(and `wurk preflight --app`) names the classes that set `lock:` when it is not.
Load Wurk first (`require "sidekiq"`, which Bundler does): the require paths are
Wurk's, added when it loads.

### Same keys, same digest: a rolling deploy needs nothing

The native copy writes and reads what the gem 8.1 writes and reads, byte for byte:

- `uniquejobs:<md5>` from `"uniquejobs:" + MD5(JSON(sorted class, queue,
  lock_args[, apartment]))` (SHA3-256 under `digest_algorithm = :modern`), and
  `lock_digest`, `lock_args`, `lock_ttl`, `lock_timeout`, `lock_prefix` in the payload;
- the STRING holding the jid, `:QUEUED` / `:PRIMED` lists, `:LOCKED` hash, `:INFO`,
  `<digest>:RUN:*` for runtime locks, the `uniquejobs:digests` and
  `uniquejobs:expiring_digests` sorted sets, `uniquejobs:changelog`, and the
  `uniquejobs:reaper` key that elects one reaper per fleet.

So a lock taken by a pod still on the gem holds against a pod on Wurk native, and
the reverse; a job either one pushed is run and unlocked by either one. Deploy the
gem removal like any other change. `test/ecosystem/sidekiq-unique-jobs-native/interop.rb`
proves it on every ecosystem run: a pod running the real gem and a pod running
the native copy share one Redis and check each other's digests, push locks,
runs and releases, `while_executing` reschedules, `until_and_while_executing`
runtime locks, scheduled jobs, retries and deaths.

With the gem **in** the bundle, the gem owns `SidekiqUniqueJobs` and the native
copy stands down: a native middleware left in a chain passes every job through and
logs once that it did. Nothing is ever locked twice.

### What is supported

| `sidekiq-unique-jobs` | Native |
|---|---|
| `lock: :until_executed` (and `:until_completed`, `:until_performed`, `:until_processed`, `:until_successfully_completed`) | ✅ locked at push, unlocked after `perform` returns; kept across a failure and its retries |
| `lock: :until_executing` (`:while_enqueued`) | ✅ unlocked just before `perform`; taken back if `perform` raises |
| `lock: :while_executing` (`:around_perform`, `:while_busy`, `:while_working`), `:while_executing_reject` | ✅ no push lock; a runtime lock on `<digest>:RUN` around `perform` |
| `lock: :until_and_while_executing` | ✅ the push lock, handed to a runtime lock as `perform` starts |
| `lock: :until_expired` | ✅ held until `lock_ttl`, whatever `perform` does |
| `config.add_lock`, `config.add_strategy` | ✅ |
| `lock_args_method:` a Proc or a Symbol; a `lock_args` / `unique_args` class method; the same in `default_job_options` | ✅ the method sees the args after a JSON round trip. A String is ignored, as by the gem |
| `lock_ttl:` (Integer, String, Proc, Symbol, Duration), `config.lock_ttl` | ✅ plus the wait until `at` for a scheduled job |
| `lock_timeout:`, `config.lock_timeout` | ✅ how long a runtime lock waits for the holder; `nil` waits 1 s, as the gem does, and a wait is capped at 5 s |
| `lock_prefix:`, `lock_limit:`, `lock_info:` | ✅ |
| `on_conflict:` `:log`, `:reject` (to the dead set, death handlers not called), `:reschedule` (`schedule_in:`, default 5 s), `:raise` (`SidekiqUniqueJobs::Conflict`), `:replace`, and `{ client:, server: }` | ✅ |
| `unique_across_queues:`, `unique_across_workers:`, the `apartment` field | ✅ |
| `config.enabled`, `logger`, `logger_enabled`, `max_history`, `digest_algorithm`, `on_conflict` | ✅ |
| `config.reaper` (`:ruby`, `:lua`, `:none`), `reaper_count`, `reaper_interval`, `reaper_timeout` | ✅ see below |
| `SidekiqUniqueJobs::Server.configure`, its death handler, `after_unlock`, `SidekiqUniqueJobs.reflect { … }` | ✅ |
| `Digests` / `ExpiringDigests` (`entries`, `page`, `count`, `delete_by_digest`, `delete_by_pattern`), `Locksmith`, `LockDigest`, `Lock`, `Unlockable`, `Changelog`, `Lock::Validator::DEPRECATED_KEYS`, `validate_worker` | ✅ |
| A job deleted through the API (`Queue#clear`, `ScheduledSet#delete`, the dashboard) releases its lock | ✅ |
| `Script::LuaError` | ✅ raised for a failed script, matched as the gem matches it |
| `debug_lua`, `locksmith_executor`, `reaper_resurrector_*`, `raise_on_config_error` | accepted, no effect: no Lua debug log, no executor (a wait blocks on its own connection), the reaper campaigns every interval anyway |
| `require "sidekiq_unique_jobs/web"` (the Locks tab) | ⏳ not yet: keep the require out until the tab ships |
| `sidekiq_unique_jobs/testing`, `have_valid_sidekiq_options` | ❌ |
| The `uniquejobs` CLI, upgrading v6 locks, the `uniquejobs:live` / `:dead` version keys | ❌ by design: nothing to upgrade from |

Quirks kept on purpose, because they are the gem's and a fleet mixes the two:

- `until_executed` + `on_conflict: :reschedule` pushes the duplicate again with no
  lock; when it runs it needs the lock, so it runs only if the holder is done by
  then, and is dropped otherwise.
- `on_conflict: :reject` is reported by the gem's validator as wrong for the client
  side, and still sends the duplicate to the dead set there.
- A job whose lock went to another jid while it waited does not run.

### Differences that change nothing in Redis

- **Lua that names every key it touches.** The gem's `:replace` script reads
  `uniquejobs:digests` without declaring it, which Dragonfly and a strict Redis
  refuse with `Script::LuaError`; the native scripts (`lib/wurk/lua/unique_jobs_*.lua`)
  declare every key. The gem's version-upgrade scripts are not carried at all.
- **The reaper is bounded.** It reads every queue, private list, schedule, retry set
  and running job once per run, twice to catch a job moving between two reads,
  instead of once per digest. It counts a dead worker's private list as live (the
  gem cannot see those). At most `reaper_count` digests per run, stopping at
  `reaper_timeout`; skipped when the queues hold more than 1,000 jobs, as the gem
  skips it. One process runs it, the one holding `uniquejobs:reaper`, gem or native.
- **A runtime lock's wait blocks its own connection**, not a thread pool's.

### And the Enterprise API

`lock:` and `unique_for:` are separate locks with separate keys (`uniquejobs:*`
and `unique:*`). Moving a class from one to the other is an ordinary change, not a
migration step:

| `sidekiq-unique-jobs` | Wurk Enterprise API |
|---|---|
| `lock: :until_executed` | `unique_until: :success` (held through retries, released on success) |
| `lock: :until_executing` / `:while_executing` | `unique_until: :start` (released just before `perform`) |
| `lock_ttl` / `lock_timeout` | `unique_for:` — seconds, or an `ActiveSupport::Duration` |
| `lock_args_method` / custom uniqueness args | `def self.sidekiq_unique_context(job)` on the worker |
| other `lock:` modes (`:until_and_while_executing`, `:until_expired`, …) | no equivalent — only `:success` and `:start` exist |

See [§6 of the migration guide](migrate-from-sidekiq.md#6-third-party-gem-mappings)
for the surrounding gem-by-gem mapping.

---

## Gotchas

- `unique!` not called → `unique_for:` is ignored. Every job-running boot, and
  `wurk boot-check`, logs a WARN listing the affected classes (only the classes
  loaded by then).
- `unique_for` missing on the worker → no lock, silently. Uniqueness is
  opt-in per worker, not global.
- `perform_async` returning `nil` is the dedup signal. Code that does
  `Job.perform_async(x).then { |jid| … }` will `NoMethodError` on the drop.
- The digest includes the queue. Moving a job between queues, even
  temporarily, splits its lock.
- The digest includes *all* args. A timestamp, a UUID, or a hash with
  `Time.now` in it makes every push unique — use `sidekiq_unique_context`.
- Long TTLs are the failure mode that hurts. A 24-hour `unique_for` plus one
  SIGKILL means a day of silently dropped pushes.
- `unique_until: :success` holds the lock across the entire retry chain. If
  your retry backoff can exceed `unique_for`, the lock expires mid-chain and a
  duplicate becomes enqueueable.
- Custom `sidekiq_unique_context` requires the worker class to be **loaded** in
  the enqueuing process, or the default triple is used instead.
- No dashboard surface for `unique_for:` locks. Use `Unique.locked?` or `redis-cli`.

---

## Related

- [Migrating from Sidekiq](migrate-from-sidekiq.md) — gem-by-gem mappings,
  including `sidekiq-unique-jobs`.
- [Rate limiting](rate-limiting.md) — concurrent limiters, for "one at a time"
  rather than "one enqueued".
- [Running Wurk](running.md) — processes, signals, and where initializers load.
- [Dashboard](dashboard.md) — what the UI does and does not show.
