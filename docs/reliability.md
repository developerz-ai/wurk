# Reliability

Wurk's job-delivery guarantee is **at-least-once**, and it is on by default —
there is no "basic fetch" mode to opt out of and no Pro toggle to turn on. This
page describes exactly what protects a job at each hop, and — just as
importantly — the three places where a job can still be lost or run twice.

The path a job takes:

| Hop | Mechanism | Loss window |
|---|---|---|
| `perform_async` → Redis | Client push (optional [outage buffer](#client-side-redis-outage-buffering)) | Redis unreachable and buffering off → the call raises |
| `schedule` / `retry` ZSET → queue | Scheduler poller | Pop-then-push window, unless [`reliable_scheduler!`](#the-reliable-scheduler) |
| queue → worker | [Reliable fetch](#reliable-fetch) (BLMOVE + private list) | None — that's the point |
| worker → done | ACK on completion, [reaper](#the-reaper) on death | None, but **duplicate execution is possible** |

---

## The guarantee, and its limits

**A job accepted into Redis will be executed at least once, unless you kill it.**

What that buys you: `SIGKILL`, an OOM kill, a lost EC2 instance, a container
eviction, or a hard `deploy` mid-perform all end with the job back on its public
queue and re-run by a live worker.

What it does **not** buy you:

- **Exactly-once.** A job that dies mid-`perform` is re-run **from the
  beginning**. Every side effect it had already committed happens again.
  Idempotency is [your responsibility](#idempotency-is-yours).
- **Durability of anything Redis itself loses.** Wurk's guarantee is scoped to
  "once the payload is in Redis". If your Redis has no AOF, or fails over to a
  replica that hadn't received the write, the job is gone and no Wurk mechanism
  can recover it. Persistence and replication policy are yours.
- **Jobs still in the client-side outage buffer.** In-memory, per-process.
  Process dies → buffered jobs are gone. See the
  [caveat](#the-durability-caveat).
- **Jobs killed as poison pills.** A job recovered `3` times inside 72h is moved
  to the dead set instead of re-queued. It's preserved, but it stops running.
- **Due jobs promoted by the default scheduler.** See
  [the reliable scheduler](#the-reliable-scheduler).

---

## Reliable fetch

`Wurk::Fetcher::Reliable` is the only fetcher Wurk ships. Every fetch is an
atomic move, never a destructive pop.

```
LMOVE  queue:default  queue:default|web-1|4711|0  RIGHT LEFT
```

The destination is the **private list** — one per (public queue, process):

```
queue:<public queue name>|<host>|<pid>|<index>
```

- `<host>` is `ENV["DYNO"]` when set, otherwise `Socket.gethostname`.
- `<index>` is currently always `0` — one fetcher per capsule.
- Pipe separators, matching Sidekiq Pro's `super_fetch` naming byte-for-byte, so
  third-party tooling that parses these keys keeps working.

The job stays in that private list for the entire duration of `perform`. Only
when the Processor finishes does it ACK:

```
LREM  queue:default|web-1|4711|0  1  <job JSON>
```

`count = 1` is safe because every payload carries a unique `jid`.

The job is ACKed when the job succeeded **or** when the retry layer booked the
outcome (scheduled a retry, sent it to the dead set, or a middleware
re-enqueued it). If neither happened — the process died — the payload is still
sitting in the private list.

**That is why `SIGKILL` is safe.** There is no in-memory-only state to lose: at
every instant, the payload exists in Redis, in exactly one of the public queue
or one private list.

### Fetch order and polling

Wurk walks the served queues in order with non-blocking `LMOVE`, then falls back
to a blocking `BLMOVE` on the first queue so an idle worker doesn't spin Redis.
`BLMOVE` has no multi-key form, so single-queue blocking is the best Redis
offers.

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.fetch_poll_interval = 5   # BLMOVE block timeout, seconds
end
```

Default is `Wurk::Fetcher::Reliable::TIMEOUT`, **2 seconds**. The socket read
timeout is set one second wider than the block window so a legitimately blocked
`BLMOVE` never trips it.

Paused queues (`SMEMBERS paused`) are skipped on every fetch pass. In-flight
jobs on a paused queue continue to completion.

### Graceful shutdown

On `SIGTERM`, in-flight jobs get until `shutdown_timeout` (default **25s**,
`config[:timeout]`) to finish. Whatever is still running at the deadline is
moved private-list → public queue by `bulk_requeue`, using an LREM-guarded
`RPUSH` in one Lua hop, before the threads are killed.

The LREM guard is what makes this safe against the race where a Processor ACKs
between the snapshot and the move: LREM removes 0 → RPUSH is skipped → a
finished job is never resurrected. `RPUSH` (tail) is deliberate — `LMOVE` pops
the tail, so the reclaimed job is fetched *next*, ahead of fresh enqueues.

> **Divergence from Sidekiq Pro.** Pro's `super_fetch` leaves in-flight jobs in
> the private list until the process boots again. Wurk moves them back to the
> public queue immediately, so a rolling deploy recovers the work without
> waiting for a restart.

---

## The reaper

`bulk_requeue` covers a *graceful* exit. `Wurk::Fetcher::Reaper` covers everything
else: a `kill -9`, a segfault, an OOM kill, a vanished host. Those leave private
lists nobody will ever ACK.

Every worker process runs a reaper thread (`wurk-reaper`). It does two passes:

| Pass | Scope | Cadence | Redis lock key |
|---|---|---|---|
| Scoped | `SCAN MATCH queue:<served queue>\|*` for queues this process serves | every `60s` (`Reaper::DEFAULT_INTERVAL`) | `super_fetch:reaper` |
| Full | `SCAN MATCH queue:*\|*` — the entire keyspace | at most every `3600s` (`Reaper::FULL_INTERVAL`) | `super_fetch:reaper:full` |

Both passes are gated by a cluster-wide `SET <key> 1 NX EX <interval>`, so
exactly one process in the fleet actually sweeps per interval no matter how many
are running. This is deliberately **leader-independent** — it keeps working if
the leader election is down.

The full pass exists because the scoped pass only looks at queues *someone
currently serves*. A private list belonging to a decommissioned or renamed queue
would otherwise be stranded forever.

There's also a **boot-time sweep**: every process runs one unguarded scoped
`reclaim!` on a background thread at startup, with no cluster lock. A SIGKILLed
sibling's jobs are recovered as soon as the replacement boots, not up to a
minute later.

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config[:super_fetch_reaper_interval] = 30   # seconds; default 60
end
```

### How "dead" is decided

Per private-list owner, and the answer differs by host:

- **Same host** — the OS is authoritative: `Process.kill(0, pid)`. Instant. A
  `kill -9`ed sibling is reclaimed the moment the supervisor reaps it, without
  waiting out any TTL. (`EPERM` is treated as alive.)
- **Other host** — we can't ping the pid, so we trust the heartbeat: the owner
  is alive iff some member of the `processes` set whose `info` hash still exists
  shares its `<host>:<pid>` prefix. The heartbeat hash has a **60s TTL**, so
  **cross-host reclaim can lag up to ~60 seconds.** Bare set membership isn't
  enough — a member lingers after its hash expires, and that window must count
  as dead.

The one blind spot is local pid reuse: if an unrelated process grabs the dead
worker's pid, the private list looks alive. In practice the supervisor respawns
with a fresh pid, so it doesn't arise.

### What reclaim actually does

Job by job, tail-to-tail:

```
LMOVE  queue:default|dead-host|9182|0  queue:default  RIGHT RIGHT
```

The move happens **before** the poison-pill check, so a crash mid-drain leaves
the job safely on the public queue — at-least-once, never lost.

### Duplicate execution — be honest about this

If a process dies **mid-`perform`**, the job had already started. Its private
list entry is reclaimed and re-pushed, and a live worker runs it **from the top**.
Any writes, emails, charges, or API calls the first attempt completed before
dying will happen a second time. Wurk cannot know how far the first attempt got.

This is the at-least-once contract, and it is identical to Sidekiq Pro's.
The mitigation is idempotent jobs, not configuration.

### Poison pills

A job that crashes its worker *every* time would loop forever. Every reclaimed
job runs through `Wurk::Middleware::PoisonPill`:

- `INCR super_fetch:recovered:<jid>` with a **72h TTL** (wire-compatible with
  Sidekiq Pro — tooling that watches those keys expects 72h).
- At `RECOVERY_THRESHOLD` (**3**) the job is killed into the dead set and
  `LREM`'d back off the public queue so it isn't also re-run.
- Statsd `sidekiq.jobs.recovered.fetch` fires on every recovery;
  `sidekiq.jobs.poison` on the kill.

Two callback surfaces, both Pro-shaped:

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.super_fetch! do |jobstr, pill|
    Rails.logger.warn "recovered: #{jobstr}"
    Rails.logger.warn "poison: #{pill.jid} #{pill.klass} #{pill.count} #{pill.queue}" if pill
  end
end

Wurk::Middleware::PoisonPill.on_poison do |info|
  Sentry.capture_message("poison pill", extra: info)   # {jid:, klass:, count:, queue:}
end
```

`Wurk::Middleware::PoisonPill.recovery_count(jid)` reads the counter without
bumping it.

---

## The reliable scheduler

**This one is not the default, and the difference matters.**

The default poller (`Wurk::Scheduled::Enq`) drains the `retry` and `schedule`
sorted sets with an atomic Lua pop-by-score, then pushes each popped job through
the client. Between the pop and the push, the job exists **only in the poller's
memory**. A crash, or a raise inside the push, loses it. The loss is reported
through your error handler (`context: "scheduler_promote"`) — but the job is
gone.

`reliable_scheduler!` closes that window by swapping in
`Wurk::Scheduled::ReliableEnq`, which promotes due jobs in a single atomic Lua
script: `ZRANGEBYSCORE` → `SADD queues` → `LPUSH queue:<name>` → `ZREM`. Push
before remove, so the worst case is a crash between them — an at-least-once
redelivery, never a loss.

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.reliable_scheduler!
end
```

- Promotes in batches of `PROMOTE_BATCH` (**500**) per Lua call, looping until a
  short batch signals the backlog is dry. Redis Lua is atomic and
  single-threaded — an unbatched sweep of a 100k-member post-outage backlog
  would block every client for its whole duration.
- Not compatible with Redis Cluster: the script touches multiple slots.

Poll cadence is the same either way: one poller thread per process, waking on a
randomized interval of `process_count * average_scheduled_poll_interval`
(default `5`), with a `10s` initial wait so a fleet-wide deploy doesn't dogpile
Redis. Total scheduler traffic therefore stays roughly constant as you add
processes.

> **Divergence from the "it's already the default" claim.** Reliable *fetch* is
> the default. The reliable *scheduler* is not — you must call
> `reliable_scheduler!` to get it. If job loss on scheduler promotion is
> unacceptable to you, turn it on.

---

## Client-side Redis-outage buffering

By default, `perform_async` during a Redis outage raises. `reliable_push!`
turns that into an in-process ring buffer that replays when Redis comes back.

```ruby
# config/initializers/wurk.rb   (top level — NOT inside Wurk.configure_*)
Wurk::Client.reliable_push! unless Rails.env.test?
```

`Sidekiq::Client.reliable_push!` is the same method — `Sidekiq::Client` is
`Wurk::Client`.

| Setting | Default | Notes |
|---|---|---|
| `Wurk::Client.reliable_push_buffer = 5_000` | `1_000` | Positive Integer, else `ArgumentError` |
| `Wurk::Client.reliable_push_overflow = :raise` | `:drop_oldest` | `:drop_oldest` is the Pro ring-buffer behavior |
| `Wurk::Client.reliable_push?` | — | Is it installed |
| `Wurk::Client::Buffered.buffer_size` | — | Current depth |

What gets caught: `RedisClient::ConnectionError` (after `Wurk::RedisPool`'s own
retries — 3 attempts with exponential backoff) and `ConnectionPool::TimeoutError`
(checkout starvation).

**Flush behavior.** Every subsequent `push` / `push_bulk` drains the buffer
oldest-first *before* pushing the new job. Draining stops at the first transient
failure and un-shifts the payload back to the head, so order is preserved and
the same job is retried next time. Non-transient errors (OOM, LOADING, READONLY)
also restore the payload before propagating, so a recovering-but-not-ready Redis
can't silently eat one buffered job per tick. Each drained payload increments
statsd `sidekiq.jobs.recovered.push`.

That passive path only fires if something pushes. If your producer goes quiet
mid-outage, the buffer sits there. Wurk adds an opt-in background drainer
(a Wurk extension beyond the Pro spec):

```ruby
Wurk::Client.reliable_push_drainer(interval: 2.0)   # implies reliable_push!
Wurk::Client.reliable_push_drainer_running?         # => true
Wurk::Client.reliable_push_drainer_stop!
```

**What is not buffered.** Payloads carrying a `bid` — batch creation and
batch-context pushes. Those re-raise, because the batch Lua has atomic counter
side effects that can't be safely replayed. In a mixed `push_bulk`, the bidless
payloads buffer and the batched ones raise.

### The durability caveat

**The buffer is in-memory and per-process. If the process dies, every buffered
job is gone.** Not written to Redis, not written to disk, not recoverable, not
logged as a payload you can replay.

`reliable_push` buys you a bounded window over a *short* Redis blip in a
*surviving* process. It is not a durable outbox. If losing an enqueue is
genuinely unacceptable, write the intent to your own database inside the
business transaction and enqueue from there — that's the outbox pattern, and
Wurk doesn't implement it for you.

Under `:drop_oldest` (the default), sustained outage past the cap silently
evicts your **oldest** jobs. Use `:raise` if you'd rather decide yourself:

```ruby
Wurk::Client.reliable_push_overflow = :raise

begin
  MyJob.perform_async(id)
rescue Wurk::Client::Buffered::Overflow => e
  Outbox.create!(payload: e.payload)   # the offending payload rides along
end
```

---

## Transaction-aware client

A different failure mode entirely, and a common production bug:

```ruby
ActiveRecord::Base.transaction do
  order = Order.create!(...)
  OrderJob.perform_async(order.id)   # Redis write is NOT transactional
  raise ActiveRecord::Rollback       # row is gone; the job is not
end
```

The job is already in Redis. A worker picks it up, looks for the order, and
finds nothing.

`Wurk::TransactionAwareClient` defers the Redis write to the surrounding
transaction's commit:

```ruby
# config/initializers/wurk.rb
Wurk.transactional_push!    # Sidekiq.transactional_push! is an alias
```

This sets `default_job_options["client_class"]`, so every `perform_async`
builds the deferring client. Per-job override via `set(client_class: …)`.

- **The `jid` is pre-allocated and returned synchronously**, so you can
  reference it inside the transaction even though the write hasn't happened.
- Dispatch is `ActiveRecord.after_all_transactions_commit` (AR 7.2+), falling
  back to the `after_commit_everywhere` gem, falling back to an immediate
  yield. AR's hook runs the block *now* when no transaction is open — so "not
  in a transaction" and "ActiveRecord absent" both degrade gracefully to a
  normal push.
- **`push_bulk` is never deferred** (Sidekiq parity — the batching/scheduling
  machinery can't ride a commit hook).
- **Pushes inside a `Batch#jobs` block are never deferred** either: the batch
  counts jobs at push time, so deferring would desync its totals.

---

## Sidekiq Pro compatibility

An existing Pro initializer drops in unchanged. What each call actually does
here:

| Pro call | Wurk behavior |
|---|---|
| `config.super_fetch!` | **Effectively a no-op** — reliable fetch is already the only fetcher. The optional block *is* honored: it's stored as the recovery callback and fired per orphan recovery (`pill` nil) and per poison kill (`pill` set). |
| `config.reliable_scheduler!` | **A real call.** Swaps `scheduled_enq` to the atomic promoter. Idempotent. |
| `Sidekiq::Client.reliable_push!` | **A real call.** Installs the outage buffer. Idempotent. |
| `config.fetch_poll_interval =` | **A real call.** Overrides the 2s `BLMOVE` block timeout. |
| `retry: :reliable` | Accepted; the private-list-until-ack behavior it names is already how every job runs. |

Key schema, counter keys, TTLs, lock names, and statsd metric names all match
Pro exactly — external tooling built against `super_fetch:recovered:*`,
`super_fetch:reaper`, `sidekiq.jobs.poison`, or the `queue:<q>|<host>|<pid>|<idx>`
naming works unchanged.

---

## Operating it

### What to monitor

| Signal | Where | Means |
|---|---|---|
| `sidekiq.jobs.recovered.fetch` | statsd (tags `class:`, `queue:`) | Workers are dying with jobs in flight. A steady non-zero rate is a bug, not noise. |
| `sidekiq.jobs.poison` | statsd | A job crossed 3 recoveries in 72h and was killed. Page on this. |
| `sidekiq.jobs.recovered.push` | statsd | Enqueues were buffered through a Redis outage and have now landed. |
| `Wurk::Client::Buffered.buffer_size` | in-process | Non-zero means Redis is unreachable *right now* from this process. |
| Dead set growth | dashboard | Includes poison-pill kills. |
| `queue:*\|*` key count | Redis | Should be ~(processes × queues). A persistent excess means orphaned private lists the reaper isn't clearing. |

Statsd metrics require a client — they're a no-op until you wire one up:

```ruby
Wurk.configure_server do |config|
  config.dogstatsd = -> { Datadog::Statsd.new("metrics.example.com", 8125) }
  config.server_middleware { |chain| chain.add Wurk::Metrics::Statsd }
end
```

A quick manual check for stranded private lists:

```bash
redis-cli --scan --pattern 'queue:*|*' | head -50
```

Anything whose `<host>|<pid>` doesn't correspond to a live process should
disappear within one reaper interval (60s same-host) or one heartbeat TTL
(~60s cross-host). If it doesn't, check that reaper threads are actually
running and that no process is holding the `super_fetch:reaper` lock without
sweeping.

### Idempotency is yours

At-least-once means **write your jobs so a second execution is harmless.** Wurk
provides no exactly-once mechanism, and no configuration will give you one.

Practical rules:

- Key side effects on something stable (`order.id`), not on the attempt.
- Guard external calls with an idempotency key the remote service honors
  (Stripe, most payment APIs).
- Prefer `find_or_create_by!` / upserts over blind `create!`.
- Make the job re-entrant: check whether the work is already done and return
  early, rather than assuming it isn't.
- Assume the job can be interrupted at *any* line, including between two writes
  that "obviously" happen together — wrap those in a DB transaction.

The one thing you should not do is disable reliability to avoid duplicates.
There is no such setting, and losing jobs is worse.

---

## Related

- [Deployment](deployment.md) — signals, rolling restarts, and what a graceful
  drain actually waits for.
- [Running Wurk](running.md) — process topology, queues, and concurrency.
- [Migrating from Sidekiq](migrate-from-sidekiq.md) — what changes on the
  one-line gem swap.
