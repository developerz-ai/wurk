# Retries, backoff & the dead set

When `perform` raises, Wurk does not lose the job. It stamps the error onto the
job payload, drops it into the `retry` sorted set with a future timestamp, and
a poller promotes it back onto its queue when the time comes. After enough
failures the job stops retrying and lands in the dead set (the "morgue"), where
it sits until you retry it, delete it, or it ages out.

All of it is wire-compatible with Sidekiq: the same `retry` / `dead` ZSETs, the
same score format, the same `error_class` / `retry_count` / `failed_at` payload
fields. Every class below is aliased — `Sidekiq::RetrySet`, `Sidekiq::DeadSet`,
`Sidekiq::ScheduledSet`, `Sidekiq::SortedEntry`, `Sidekiq::JobRetry` — so an
existing Sidekiq initializer, death handler, or ops script keeps working on the
one-line gem swap.

| Surface | What it controls |
|---------|------------------|
| `sidekiq_options retry:` | Whether and how many times a job retries |
| `sidekiq_options retry_for:` | Retry by elapsed wall-clock instead of a count |
| `sidekiq_options retry_queue:` | Which queue retries go back onto |
| `sidekiq_options dead:` | Whether an exhausted job reaches the morgue |
| `sidekiq_options backtrace:` | Whether the backtrace is stored on the payload |
| `sidekiq_retry_in { }` | Per-class custom backoff, `:discard`, or `:kill` |
| `sidekiq_retries_exhausted { }` | Per-class callback on the final failure |
| `config.death_handlers` | Global callback on every death |
| `config[:max_retries]` | Fleet-wide default attempt count (default `25`) |
| `config[:dead_max_jobs]` | Morgue capacity (default `10_000`) |
| `config[:dead_timeout_in_seconds]` | Morgue TTL (default 180 days) |

---

## The lifecycle of a failing job

1. **`perform` raises.** The Processor wraps every job in two retry guards:
   `JobRetry#global` (outermost, no worker instance needed — catches
   const-lookup and reloader failures too) and `JobRetry#local` (inner, runs
   once the worker instance exists so per-class blocks can fire). Both rescue
   `Exception`, not just `StandardError`.

2. **`Wurk::Shutdown` is exempt.** If the exception *is* a shutdown, or has one
   anywhere in its `cause` chain, it is re-raised instead of booked as a
   failure. A `rescue => e` in your job that swallows a shutdown will not
   silently turn a deploy into 5,000 retries.

3. **The error is stamped onto the payload.**

   | Field | Value |
   |-------|-------|
   | `error_class` | `exception.class.name` |
   | `error_message` | `exception.message`, truncated to 10,000 chars, forced to UTF-8 and scrubbed |
   | `retry_count` | `0` on the first failure, `+1` on each subsequent one |
   | `failed_at` | epoch **milliseconds**, set on the first failure only |
   | `retried_at` | epoch milliseconds, set on every failure after the first |
   | `error_backtrace` | only when `backtrace:` is set — `base64(zlib(JSON(lines)))` |

4. **The queue is decided.** `msg["queue"]` becomes `retry_queue` if the class
   sets one, otherwise the queue the job was running on.

5. **Exhaustion is checked** (see [§ Exhaustion](#exhaustion)). If the job is
   done retrying, it goes to the morgue path instead of the retry set.

6. **The delay is computed** and the payload is `ZADD`ed into the `retry` ZSET
   with score `now + delay + jitter` (epoch float seconds). A
   `jobs.retried` statsd counter is incremented, tagged with worker class and
   queue.

7. **The unit of work is acked.** `JobRetry` raises `Handled`, which the
   Processor treats as a clean exit — the payload is removed from the
   per-process private list. The only copy of the job now lives in `retry`.

8. **The scheduler promotes it.** One `Scheduled::Poller` thread per process
   wakes on a randomized interval and drains both the `retry` and `schedule`
   ZSETs via an atomic Lua pop-by-score, pushing each due job back onto
   `queue:<name>`. The poll cadence scales with the number of live processes
   (`process_count * config[:average_scheduled_poll_interval]`, default `5`),
   so total scheduler traffic against Redis stays roughly constant as you add
   processes. The first sweep of a freshly booted process waits 10 seconds so a
   fleet-wide deploy doesn't dogpile Redis.

9. **A worker picks it up again**, and the loop repeats from step 1 — with
   `retry_count` one higher.

10. **Retries run out.** The per-class `sidekiq_retries_exhausted` block runs,
    the payload is `ZADD`ed into the `dead` ZSET, the morgue is trimmed on both
    axes, and every `config.death_handlers` entry fires.

Redis structures involved, all unnamespaced and identical to Sidekiq:

| Key | Type | Role |
|-----|------|------|
| `queue:<name>` | LIST | The live queue |
| `retry` | ZSET | Pending retries, score = epoch float seconds of next attempt |
| `schedule` | ZSET | Future-dated jobs (`perform_in`), drained by the same poller |
| `dead` | ZSET | The morgue, score = epoch float seconds of death |
| `stat:failed`, `stat:failed:YYYY-MM-DD` | STRING | Failure counters |

> **A `SIGKILL`ed process is not a failure.** The in-flight payload never
> leaves the per-process private list, so it is reclaimed by the reaper on the
> next boot and re-run — no `retry_count` bump, no dead-set entry.

---

## `retry:` — what each value does

Set on the class with `sidekiq_options`. The default for every job is
`retry: true` (`Wurk::DEFAULT_JOB_OPTIONS`).

```ruby
# app/jobs/charge_job.rb
class ChargeJob
  include Wurk::Job

  sidekiq_options retry: 5, queue: "payments"

  def perform(charge_id) = Charge.find(charge_id).submit!
end
```

| Value | Behavior on failure |
|-------|---------------------|
| `true` (default) | Retry up to `config[:max_retries]` times — `25` unless you change it |
| an Integer `N` | Retry up to `N` times, then dead set |
| `0` | No retry at all; the **first** failure goes straight to the dead set |
| `false` | No retry, **no dead set** — death handlers fire and the job is gone |

The distinction between `0` and `false` matters. `retry: 0` still counts as
"retryable with zero attempts left", so the first failure runs the exhaustion
path: `sidekiq_retries_exhausted`, morgue, death handlers. `retry: false`
short-circuits earlier — the exception propagates out of the inner guard to the
outer one, which runs `config.death_handlers` and drops the job on the floor.
Nothing is written to `retry` or `dead`. If you set `retry: false`, your death
handler *is* your error reporting.

`retry: N` counts retries, not executions: `retry: 5` means one initial attempt
plus five retries, six runs total.

### Related options

```ruby
class ReportJob
  include Wurk::Job

  sidekiq_options retry: 10,
                  retry_queue: "low",   # retries go here, not back to the origin queue
                  backtrace: 20,        # store the first 20 backtrace lines on the payload
                  dead: false           # exhausted → discarded, never reaches the morgue
end
```

- **`retry_queue:`** — retries are re-enqueued onto this queue instead of the
  one they failed on. Useful for keeping a flapping job out of a latency-
  sensitive queue.
- **`backtrace:`** — `true` stores every line, an Integer stores the first N.
  Stored compressed (`base64(zlib(JSON))`) to keep the Redis payload bounded.
  Off by default; the dashboard can only show a backtrace when this is set. A
  `config[:backtrace_cleaner]` callable, if registered, filters the lines
  before they're stored.
- **`dead: false`** — the job still retries normally, but on exhaustion it is
  discarded (`discarded_at` stamped, death handlers fired) rather than written
  to the morgue.
- **`retry_for:`** — retry by elapsed time instead of attempt count. Takes
  seconds. When set, **the count-based limit is ignored entirely**: the job
  keeps retrying until `failed_at + retry_for` is in the past, then exhausts.
  Values above 1,000,000,000 are rejected at enqueue time with an
  `ArgumentError`.

### `timeout:` and `deadline:` — bounding how long a job may run

Two Wurk extras (no Sidekiq equivalent) that guard wall-clock time, both
backed by one monotonic watchdog thread per worker process — never armed, and
so free, unless a job declares a bound:

```ruby
class SlowJob
  include Wurk::Job

  sidekiq_options timeout: 30    # seconds, per attempt
  # sidekiq_options deadline: 300  # seconds, from enqueue — mutually independent
end
```

| Option | Bounds | On expiry | Retries? |
|---|---|---|---|
| `timeout:` | One attempt | `Wurk::Job::TimedOut` raised into the running thread | **Yes, if it escapes `perform`** — then the ordinary failure path: booked as a failure, retried on the class's own `retry:` policy. A `perform` that rescues it swallows the retry too |
| `deadline:` | The job as a whole, from enqueue | `Wurk::Job::DeadlineExceeded` raised (if already running) or the job dropped before `perform` starts (if the window already closed) | **No** — terminal `expired` state, same as `expires_in:` ([reliability.md](reliability.md)) |

- **`timeout:`** is per attempt: a retried job that timed out gets the full
  budget again on its next run. It is soft — `Thread#raise`, not
  `Thread#kill` — so a `perform` that swallows `StandardError` swallows this
  too, the same bargain stdlib `Timeout` and Celery's soft time limit make.
- **`deadline:`** is resolved to an absolute cutoff once, at push, so retries
  and `IterableJob` resumes all draw from the *same* budget rather than each
  getting a fresh one. Past the cutoff the job never runs (or is cut mid-run)
  and lands in the same `expired` terminal state `expires_in:` produces —
  bumps `stat:expired` and `jobs.expired`, no retry, no dead-set entry.
- Both bounds race `shutdown_timeout` — and the comparison is between what's
  *left* of each, not between the configured numbers. A bound whose remaining
  budget is shorter than the remaining drain fires first and the job retries
  normally; otherwise graceful shutdown unwinds the job with `Wurk::Shutdown`
  instead and the payload is reclaimed from the private list on the next boot.
  So a 30s `timeout:` can still beat a 10s drain: an attempt already 25s in has
  5s of budget left when the `TERM` lands.
- A worker can declare `timeout:`, `deadline:`, both, or neither — they answer
  different questions ("how long may one attempt take" vs "how long may the
  whole job take") and aren't mutually exclusive.

---

## Backoff

The default delay, in seconds, where `count` is the job's `retry_count`
*after* the current failure was booked (so `0` on the first failure):

```
delay    = (count ** 4) + 15
jitter   = rand(10 * (count + 1))
retry_at = Time.now.to_f + delay + jitter
```

The jitter is uniform, non-negative, and grows with the attempt number — it
exists so a Redis outage that fails 10,000 jobs at once doesn't cause all
10,000 to come back in the same second.

| `retry_count` | Base delay | Jitter | Actual wait |
|---|---|---|---|
| 0 | 15s | 0–9s | 15–24s |
| 1 | 16s | 0–19s | 16–35s |
| 2 | 31s | 0–29s | 31–60s |
| 3 | 96s | 0–39s | ~1.6–2.3 min |
| 4 | 271s | 0–49s | ~4.5–5.3 min |
| 5 | 640s | 0–59s | ~11–12 min |
| 10 | 10,015s | 0–109s | ~2.8 hours |
| 15 | 50,640s | 0–159s | ~14 hours |
| 20 | 160,015s | 0–209s | ~1.9 days |
| 24 | 331,791s | 0–249s | ~3.8 days |

Twenty-five retries at the default formula span just over 20 days of
wall-clock before the job dies. If that's longer than your incident response
window, lower `retry:` per class rather than leaving jobs to rot in `retry`.

### Custom backoff — `sidekiq_retry_in`

```ruby
# app/jobs/api_sync_job.rb
class ApiSyncJob
  include Wurk::Job

  sidekiq_retry_in do |count, exception, jobhash|
    case exception
    when RateLimited      then 60 * (count + 1)   # linear, 1 min per attempt
    when RecordNotFound   then :discard           # gone for good; don't bury it
    when CorruptPayload   then :kill              # bury it for inspection
    else                       nil                # fall back to the default formula
    end
  end

  def perform(id) = ExternalApi.sync!(id)
end
```

The block is called with three arguments in this order:

| Arg | Value |
|-----|-------|
| `count` | `retry_count` after the current failure — `0` on the first failure |
| `exception` | The exception instance that was raised |
| `jobhash` | The full job payload Hash, already stamped with `error_class` etc. |

Return values the code honors:

| Return | Effect |
|--------|--------|
| positive Integer | Used as the delay in seconds; **jitter is still added on top** |
| Float | Truncated to an Integer, then treated as above |
| `:discard` | `discarded_at` is stamped, death handlers fire, nothing is written to `retry` or `dead` |
| `:kill` | Takes the exhaustion path immediately: `sidekiq_retries_exhausted`, morgue, death handlers |
| `nil`, `0`, a negative Integer, or anything else | Falls back to the default `(count ** 4) + 15` formula |

If the block itself raises, the exception is routed to your error handlers with
context `"Failure scheduling retry via \`sidekiq_retry_in\`"` and the default
formula is used. A broken backoff block can't strand a job.

For ActiveJob and other wrapper classes, the block is looked up on the wrapped
class (`jobhash["wrapped"]`) first and falls back to the wrapper's own block.

---

## Exhaustion

A job stops retrying when either condition holds:

- `retry_for` is set on the payload and `failed_at + retry_for` is in the past
  (when `retry_for` is set, the attempt count is not consulted at all), **or**
- `retry_count >= max_attempts`, where `max_attempts` is `retry:` when it's an
  Integer, otherwise `config[:max_retries]`, otherwise `25`.

Then, in this exact order:

1. **`sidekiq_retries_exhausted`** — the per-class block, if defined.
2. **Morgue or discard** — unless the block returned `:discard` or the payload
   has `dead: false`, the job is written to the dead set. Otherwise
   `discarded_at` is stamped and nothing is written.
3. **`config.death_handlers`** — every registered global handler, in
   registration order. These fire **on every death**, morgue or discard,
   including the `retry: false` path and `:discard` from `sidekiq_retry_in`.

### `sidekiq_retries_exhausted`

```ruby
# app/jobs/import_job.rb
class ImportJob
  include Wurk::Job

  sidekiq_retries_exhausted do |jobhash, exception|
    Import.find(jobhash["args"].first).update!(state: "failed")
    :discard   # optional — skip the morgue for this class
  end

  def perform(import_id) = Import.find(import_id).run!
end
```

Two arguments: the job payload Hash and the exception. Returning `:discard`
keeps the job out of the morgue. Any other return value is ignored. If the
block raises, the error goes to your error handlers with context
`"Error calling retries_exhausted"` and the job still proceeds to the morgue.

### Global death handlers

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.death_handlers << lambda do |job, exception|
    Sentry.capture_exception(
      exception,
      extra: { jid: job["jid"], class: job["class"], args: job["args"] }
    )
  end
end
```

`death_handlers` is a plain Array on the config — push callables onto it.
`Sidekiq.configure_server` is the alias, so an existing Sidekiq initializer
needs no change.

- Every handler receives `(job_hash, exception)`.
- Handlers are called in registration order; a handler that raises
  `StandardError` is reported to your error handlers with context
  `"Error calling death handler"` and the remaining handlers still run.
- They fire on **manual kills too**. `DeadSet#kill` and `SortedEntry#kill`
  default to `notify_failure: true`, and when there's no real exception they
  synthesize `RuntimeError.new("Job killed by API")` — matching Sidekiq
  byte-for-byte, so handlers that pattern-match on that message keep working.
  Pass `notify_failure: false` to suppress.

---

## The dead set

A capped ZSET at the `dead` key, scored by time of death.

| Knob | Default | Effect |
|------|---------|--------|
| `config[:dead_max_jobs]` | `10_000` | Maximum entries; the oldest are evicted past this |
| `config[:dead_timeout_in_seconds]` | `15_552_000` (180 days) | Entries older than this are evicted |

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config[:dead_max_jobs] = 50_000
  config[:dead_timeout_in_seconds] = 30 * 24 * 60 * 60
end
```

Trimming runs on **every** write to the morgue — exhausted retries, API kills,
and unparseable payloads alike. It's a two-axis pipelined trim:
`ZREMRANGEBYSCORE` drops everything older than the timeout, then
`ZREMRANGEBYRANK 0 -dead_max_jobs` drops the oldest entries beyond the cap.
Eviction is oldest-first; there is no priority or per-class quota. **A busy
morgue silently evicts your older evidence** — if you care about a dead job,
get it out of the set, don't rely on it still being there tomorrow.

Malformed JSON on the queue also lands here: the Processor can't parse it, so
it reports the `JSON::ParserError`, writes the raw bytes to `dead` via
`kill_raw`, and acks. No death handlers fire — there's no parseable job to hand
one.

### From the dashboard

The **Dead** page lists entries newest-first and offers **Retry** and
**Delete**, per entry, in bulk, or across the whole set. The **Retries** page
additionally offers **Kill**, which moves an entry from `retry` straight to
`dead`. The **Scheduled** page offers **Delete** and **Add to queue**.

Mutating dashboard actions are gated by whatever auth you've configured and by
read-only mode — see [Authentication & authorization](authentication.md).

### From Ruby

The whole data API is loaded by `require "wurk"` — there's no separate api
require to remember (`require "sidekiq/api"` is accepted and just loads Wurk).

```ruby
Wurk::RetrySet.new.size        # => 143
Wurk::DeadSet.new.size         # => 12
Wurk::ScheduledSet.new.size    # => 4
```

---

## The sorted-set API

`RetrySet`, `ScheduledSet`, and `DeadSet` all subclass `JobSet` and share one
surface. Every method below is available under both the `Wurk::` and
`Sidekiq::` names.

| Method | Redis | Notes |
|--------|-------|-------|
| `size` | `ZCARD` | O(1) |
| `each { |entry| }` | paged `ZRANGE … REV` | Newest-first, 50 per page; yields `SortedEntry` |
| `scan(match)` | `ZSCAN` with `*match*` | Yields raw JSON + score |
| `find_job(jid)` | `ZSCAN` | First entry with that exact jid, or `nil`. O(n) |
| `fetch(score, jid = nil)` | `ZRANGEBYSCORE` | `score` may be a `Time`, `Numeric`, or `Range` |
| `schedule(timestamp, job)` | `ZADD` | Insert a payload at an explicit time |
| `retry_all` | — | Re-enqueue every entry; returns the count |
| `kill_all(notify_failure: true, ex: nil)` | — | Move every entry to `dead`; returns the count |
| `clear` | `UNLINK` | Drops the whole set |
| `delete_by_value(name, value)` | `ZREM` | Exact-bytes removal |
| `delete_by_jid(score, jid)` | `ZRANGEBYSCORE` + `ZREM` | Aliased as `delete` |

`Enumerable` is included, so `select`, `map`, `count`, and friends work — at
the cost of paging the whole set through Redis.

```ruby
# Find one job and act on it.
entry = Wurk::RetrySet.new.find_job("a1b2c3d4e5f6a1b2c3d4e5f6")

entry.klass          # => "ChargeJob"
entry.args           # => [42]
entry.jid            # => "a1b2c3d4e5f6a1b2c3d4e5f6"
entry.score          # => 1721480000.123  (epoch float, when it next runs)
entry.at             # => 2026-07-20 12:00:00 UTC
entry.id             # => "1721480000.123|a1b2c3d4e5f6a1b2c3d4e5f6"
entry.error?         # => true
entry["error_class"] # => "Net::ReadTimeout"
entry.failed_at      # => Time
entry.retried_at     # => Time
```

`SortedEntry` mutations:

| Method | Effect |
|--------|--------|
| `retry` | Removes the entry and re-pushes it, **decrementing `retry_count` by 1** so a manual retry doesn't consume an attempt |
| `add_to_queue` | Removes and re-pushes with the payload untouched — `retry_count` is not changed |
| `kill` | Removes and writes to the dead set, firing death handlers with the synthesized "Job killed by API" exception |
| `delete` | Removes the entry and nothing else |
| `reschedule(at)` | `ZINCRBY` to shift the entry's score to a new time |

```ruby
# Retry every dead ChargeJob for one customer.
Wurk::DeadSet.new.each do |entry|
  entry.retry if entry.klass == "ChargeJob" && entry.args.first == customer_id
end
```

Each mutation removes the entry from Redis first and only re-pushes if the
removal actually succeeded, so two operators clicking "Retry" at the same
moment can't produce two copies of the job.

`retry_all` and `kill_all` loop until the set is empty and are **not**
transactional — an error mid-iteration leaves the set partially processed.

---

## Poison pills

Retries handle jobs that *raise*. A job that kills the whole process — an OOM,
a segfault in a native extension, an infinite loop that hits the shutdown
timeout — never raises, so it never gets a `retry_count`. Its payload stays in
the dead process's private list, the reaper moves it back to the public queue,
another worker picks it up, and it kills that one too.

Wurk breaks that loop. Every job recovered from a dead process's private list
is counted at `super_fetch:recovered:<jid>` (a 72-hour-TTL counter). Once a jid
has been recovered **3** times, the next recovery is treated as a poison pill:
the payload is moved to the dead set, a `jobs.poison` statsd counter fires, the
copy on the public queue is `LREM`'d so it can't run again, and any registered
poison callbacks are invoked.

```ruby
# config/initializers/wurk.rb
Wurk::Middleware::PoisonPill.on_poison do |pill|
  # pill => { jid:, klass:, count:, queue: }
  PagerDuty.trigger("poison pill: #{pill[:klass]} #{pill[:jid]}")
end
```

Poison-pill kills pass `notify_failure: false`, so **`config.death_handlers` do
not fire for them** — register `on_poison` if you want to be paged. The Pro
`config.super_fetch! { |jobstr, pill| }` callback also fires on every recovery
(with `pill` nil on a plain recovery, populated on the kill path).

`Wurk::Middleware::PoisonPill.recovery_count(jid)` reads the counter without
bumping it; `.clear!(jid)` resets it.

---

## Operating this

**Make jobs idempotent.** Retries are at-least-once by construction: a job that
succeeds and then crashes before acking will run again, and a manual "Retry
now" from the dashboard re-runs the whole `perform`. Write jobs that can run
twice — check for the record you're about to create, use a unique constraint,
key the side effect on the jid.

**Watch the dead set's size, not just its contents.** `Wurk::Stats.new` exposes
`retry_size`, `dead_size`, and `scheduled_size`. A growing `retry_size` means
failures are outrunning recoveries; a `dead_size` pinned at `dead_max_jobs`
means you are silently evicting evidence and should raise the cap or fix the
source.

```ruby
stats = Wurk::Stats.new
stats.retry_size      # jobs waiting to be retried
stats.dead_size       # jobs that gave up
stats.failed          # lifetime failure counter
```

**Don't leave `retry: true` on jobs that can never succeed.** A job whose
arguments reference a deleted record will burn 25 attempts over 20 days for
nothing. Either return `:discard` from `sidekiq_retry_in` for that exception
class, or rescue it in `perform`.

**Don't set `retry: false` and call it error handling.** Nothing is persisted
and nothing is visible in the dashboard — a death handler is the only place the
failure surfaces.

**Set `backtrace:` on the jobs you actually debug**, not globally. It's stored
compressed, but it's still bytes in Redis on every retry of every job.

---

## Related

- [Running Wurk](running.md) — the swarm, signals, and what a graceful drain
  does to in-flight jobs.
- [Authentication & authorization](authentication.md) — gating the retry, kill,
  and delete actions in the dashboard.
- [Migrating from Sidekiq](migrate-from-sidekiq.md) — `sidekiq_options`
  mapping and the Redis key layout.
- [ActiveJob](active-job.md) — `sidekiq_options` on native Active Job classes,
  and how the wrapper payload is shaped.
