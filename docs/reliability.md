# Reliability

Wurk's job-delivery guarantee is **at-least-once**, and it is on by default —
there is no "basic fetch" mode to opt out of and no Pro toggle to turn on. This
page describes exactly what protects a job at each hop, and — just as
importantly — the three places where a job can still be lost or run twice.

The path a job takes:

| Hop | Mechanism | Loss window |
|---|---|---|
| `perform_async` → Redis | Client push (optional [outage buffer](#client-side-redis-outage-buffering)) | Redis unreachable and buffering off → the call raises |
| `schedule` / `retry` ZSET → queue | Scheduler poller | Claim, push, remove: a crash re-promotes after a 60s lease, so a duplicate is possible and loss is not |
| queue → worker | [Reliable fetch](#reliable-fetch) (BLMOVE + private list) | Nothing lost, but a claim whose reply was lost is delayed: [up to two reaper intervals](#a-live-workers-own-private-list) |
| worker → done | [ACK](#the-ack-rides-the-next-fetch) on the next fetch, [reaper](#the-reaper) on death | None, but **duplicate execution is possible** |

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

---

## Reliable fetch

`Wurk::Fetcher::Reliable` is the only fetcher Wurk ships. Every fetch is an
atomic move, never a destructive pop.

```
LMOVE  queue:default  queue:default|web-1|4711|a1b2c3d4e5f6|0  RIGHT LEFT
```

The destination is the **private list** — one per (public queue, process):

```
queue:<public queue name>|<host>|<pid>|<nonce>|<index>
```

- `<host>` is `ENV["DYNO"]` when set, otherwise `Socket.gethostname`.
- `<nonce>` is `Wurk::Component::PROCESS_NONCE` — 12 hex chars
  (`SecureRandom.hex(6)`), minted once when the process image loads and
  inherited unchanged across `fork`. It disambiguates two process
  *generations* that land on the same `<host>|<pid>` — a quick restart that
  gets pid-recycled by the OS, or a container that restarts under a fixed
  hostname into a fresh pid namespace. Without it, a reaper could match the
  new process's private list against the old (dead) process's identity, or
  vice versa.
- `<index>` is currently always `0` — one fetcher per capsule.
- Pipe separators, as in Sidekiq Pro's `super_fetch`, but **not the same key
  shape**: [Pro §3.2](target/sidekiq-pro.md#32-algorithm) specifies four parts,
  `queue:<public>|<hostname>|<pid>|<index>`. Wurk adds the nonce as a fifth
  part. Tooling that assumes Pro's fixed four-part shape must adapt; see the
  [private-list naming divergence](idea/parity-divergences.md#private-list-names-include-a-process-image-nonce).

> **Migration window.** Keys written before the nonce existed have the
> 3-segment tail `<host>|<pid>|<index>` (no nonce). The reaper's parser
> (`Fetcher::PrivateListKey.parse_full`, right-anchored via
> `owner_tails`) accepts both the 4-segment and 3-segment tail shapes, trying
> the wider (nonce-bearing) reading first and falling back to the narrow one.
> A pre-nonce key stays reclaimable indefinitely — nothing writes that shape
> anymore, but a list created by a not-yet-upgraded process can still hold
> in-flight jobs across a rolling upgrade, and dropping the narrow parse
> would strand it. See [How "dead" is decided](#how-dead-is-decided) for how
> liveness is checked differently for nonce-bearing vs. pre-nonce keys.

The job stays in that private list for the entire duration of `perform`, and
past it. It leaves only on an ACK:

```
LREM  queue:default|web-1|4711|a1b2c3d4e5f6|0  1  <job JSON>
```

`count = 1` is safe because every payload carries a unique `jid`.

A job becomes ACK-able when it succeeded **or** when the retry layer booked the
outcome (scheduled a retry, sent it to the dead set, or a middleware
re-enqueued it). If neither happened — the process died — the payload is still
sitting in the private list.

**That is why `SIGKILL` is safe.** There is no in-memory-only state to lose: at
every instant, the payload exists in Redis, in exactly one of the public queue
or one private list.

In the private list is not the same as running, though. See
[a live worker's own private list](#a-live-workers-own-private-list).

### The ACK rides the next fetch

The `LREM` is not sent the instant the Processor is done with the job. It is
held in the fetcher and pipelined with the **next** fetch's `LMOVE`, so a
worker draining a busy queue spends one Redis round trip per job in total
rather than one to fetch and another to ACK.

A pending ACK never sits on an idle worker. It is flushed, as its own round
trip, before any of:

- the fetcher blocking in `BLMOVE` (a blocking call can't join a pipeline),
- a fetch pass with nothing to fetch — every served queue paused, or none
  configured,
- `SIGTSTP` quiet, which stops the fetcher permanently and so would otherwise
  strand it until shutdown,
- the processor stopping,
- the [shutdown requeue](#graceful-shutdown).

**What this costs.** The window in which a *hard* death — `SIGKILL`, OOM kill,
lost instance — reclaims an already-finished job and runs it a second time
widens from "the microseconds after `perform` returned" to "until the next
fetch, or one of the flushes above". This is the same duplicate execution the
at-least-once contract already covers (see *Duplicate execution — be honest
about this*, below), with the same mitigation: idempotent jobs. It is not
reachable by any graceful path, and nothing can be **lost** — the payload leaves
the private list later than it used to, never earlier, so every death inside the
widened window is a reclaim, not a drop.

### Fetch order and polling

Each fetch tries a non-blocking `LMOVE` on the first queue (in strict or
weighted order, skipping paused queues); on a miss, one `fetch_first` Lua call
claims from the first non-empty queue among the rest — two round trips however
many queues a capsule serves — and only then blocks with `BLMOVE` on the first
queue so an idle worker doesn't spin Redis. `BLMOVE` has no multi-key form, so a
job arriving on a later queue while every thread is parked waits up to one poll
interval.

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.fetch_poll_interval = 5   # BLMOVE block timeout, seconds
end
```

Default is `Wurk::Fetcher::Reliable::TIMEOUT`, **2 seconds**. The socket read
timeout is set one second wider than the block window so a legitimately blocked
`BLMOVE` never trips it.

Paused queues are skipped on every fetch pass. In-flight jobs on a paused queue
continue to completion.

The `paused` SET is read with `SMEMBERS` at most once every
`Fetcher::Reliable::PAUSED_TTL` (**2 seconds**, monotonic clock) per fetcher,
not once per fetch — otherwise a queue that nobody has paused would cost a
round trip per job just to keep confirming it. A `pause!` issued from another
process therefore takes hold within `PAUSED_TTL` rather than on the very next
fetch. Issued from *inside* a worker process, it takes hold on that process's
next fetch pass.

That does not move the fleet's worst case: an idle worker is parked in `BLMOVE`
for `fetch_poll_interval` — 2 seconds by default — and can't observe a pause
until the block returns, so the cache is exactly the delay the idle path
already had. Raise `fetch_poll_interval` and the poll interval dominates.
`Wurk::Queue#paused?`, the JSON API, and the dashboard read Redis directly and
are never served from this cache.

### Graceful shutdown

On `SIGTERM`, in-flight jobs get until `shutdown_timeout` (default **25s**,
`config[:timeout]`) to finish. Pending ACKs are flushed first, then whatever is
still running at the deadline is moved private-list → public queue by
`bulk_requeue`, using a guarded `RPUSH` then `LREM` in one Lua hop, before the threads
are killed.

That ordering is load-bearing. A job that finished moments before the deadline
has an ACK still pending; requeuing before flushing it would find the payload
still in the private list, pass the guard, and re-run completed work on every
graceful shutdown.

The `LPOS` guard is what makes this safe against the race where a Processor ACKs
between the snapshot and the move: the payload is gone → RPUSH is skipped → a
finished job is never resurrected. `RPUSH` (tail) is deliberate — `LMOVE` pops
the tail, so the reclaimed job is fetched *next*, ahead of fresh enqueues.

> Wurk moves only the jobs still parked, onto the *front*, so work interrupted
> by a deploy runs next instead of waiting behind the backlog a second time
> ([parity divergences](idea/parity-divergences.md#bulk_requeue-moves-still-parked-jobs-to-the-queue-head)).

---

## The reaper

`bulk_requeue` covers a *graceful* exit. `Wurk::Fetcher::Reaper` covers everything
else: a `kill -9`, a segfault, an OOM kill, a vanished host. Those leave private
lists nobody will ever ACK.

Before draining a list judged orphaned by its heartbeat, the reaper waits out a
grace period (30s) on its own clock, then re-checks: the heartbeat must still be
missing. A missing hash does not prove a process dead. CPU-bound jobs can hold a
beat back (25 of them held one back 17.4s), its first beat can fail on a Redis blip,
and a Redis restarted from an older snapshot brings back `processes` with every hash
lapsed. In each case the next beat ends the wait, and the running jobs are left
alone. The reaper thread finishes what any of its sweeps started, with or without the
sweep lock, so the wait costs the same on every server and at every fleet size, and
reading a private list does not delay it.

Every worker process runs a reaper thread (`wurk-reaper`). Every 60s
(`Reaper::DEFAULT_INTERVAL`) it tries for the cluster-wide lock, `super_fetch:reaper`,
with a `SET NX` living 48s, so about one process sweeps per interval however many are
running, and one left alone still sweeps every time. The lock is deliberately
**leader-independent**: it keeps working if the leader election is down.

A sweep is one `SCAN MATCH queue:*\|*` acting on **every** list, not only those of
the queues the winner serves: with the lock shared across the fleet, a queue served
by one process in ten would wait about 13 intervals for its turn. It also covers a
decommissioned or renamed queue. The jobs go back to the list's own queue, whichever
process moves them.

There's also a **boot-time sweep**: every process runs one sweep on a background
thread at startup, with no cluster lock. A SIGKILLed sibling's jobs are recovered as
soon as the replacement boots.

**How long reclaim takes**, measured at the defaults on Redis 7:

| What died | Replaced by | Back on the queue after |
|---|---|---|
| A swarm child | A child of the same swarm, same nonce: the OS answers | **1.2s** |
| A standalone `wurk` (a pod restart) | A new process, new nonce: only the heartbeat can answer, and the boot sweep is too early for it | **about 91s** |
| A whole host, for good | Nothing, a survivor elsewhere sweeps | **90-141s** (bound: 80-150s; a sweeper that dies during its 30s grace restarts the clock, up to about 240s) |

A restart does not shorten the last two: nothing can tell a dead owner from a live one
until its heartbeat lapses.

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config[:super_fetch_reaper_interval] = 30   # seconds; default 60
end
```

### How "dead" is decided

Per private-list owner, and the answer now turns on nonce, not just host:

- **Our own host *and* nonce** — a key's `<host>|<pid>|<nonce>` tail matches
  this process's own `hostname` and `Component::PROCESS_NONCE`. Because the
  nonce is minted once per process image and inherited unchanged across
  `fork` (`component.rb:19-21`), this group is every process forked from the
  same swarm boot — the pid was minted in *our* pid namespace, so the OS is
  authoritative: `Process.kill(0, pid)`. Instant. It ignores a stale `processes`
  SET member — the SET has no TTL; the member lingers after its heartbeat hash
  expires (60s) until `ProcessSet#cleanup` prunes it — so a `kill -9`ed sibling
  is reclaimed once the supervisor reaps it. (`EPERM` is treated as alive.)
- **Any other incarnation** — different nonce (a different boot generation),
  a pre-nonce key, or a different host — its pid means nothing in our
  namespace, so we trust the heartbeat instead: the owner is alive iff its
  identity is a live `processes` member (one whose `info` hash still
  exists). Match is on the full `<host>:<pid>:<nonce>` for a nonce-bearing
  key, or just the `<host>:<pid>` prefix for a pre-nonce one — see the
  [migration window](#reliable-fetch) note above. The heartbeat hash has a
  **60s TTL**, so **this path lags reclaim by that TTL, a sweep interval and the
  30s grace** ([measured above](#the-reaper)). Bare set membership isn't
  enough — a member lingers after its hash expires, and that window must count
  as dead.

**The remaining blind spot, unchanged by the nonce:** pid reuse *within* the
same boot generation. If the swarm respawns a replacement and the OS hands it
the exact pid a just-reaped sibling held — same host, same inherited
nonce — the new occupant reads as the old one, alive. In practice the
supervisor's own bookkeeping means this doesn't arise (a respawned child
gets a fresh pid before its predecessor's is even eligible for reuse), so it
stays a theoretical gap rather than an operational one. This is the same
class of weakness Sidekiq Pro's `super_fetch` has never closed — see
[Parity Divergences](idea/parity-divergences.md) — recorded there as
deliberate rather than fixed, since eliminating it would mean tracking pid
generation numbers the OS doesn't expose.

### The unparseable-key warning

A `queue:*|*` key whose owner Wurk cannot read — a name whose tail is neither
`<host>|<pid>|<nonce>|<index>` nor `<host>|<pid>|<index>`, say a list another
tool wrote under the `queue:` prefix — is one the reaper can never reclaim. It
does not skip it in silence: it logs a WARN naming the key and how many jobs it
holds, and moves on. The jobs in such a list stay where they are until you move
them back by hand.

Sidekiq Pro's own four-part list (`queue:<public>|<host>|<pid>|<index>`) **is**
read — it is the pre-nonce shape — so it is reclaimed like any other, not
skipped.

**That warning is per process, and it repeats.** The set of already-reported
keys is an in-memory `Set` held by the reaper — one instance per worker
process, built after the fork. There is no Redis key behind it, no TTL, and
nothing shared with the other workers:

- A sweep reports the key in the process running it, so over time **every worker**
  reports the key for itself: one identical WARN per worker pid, and the pid in the
  log line tells them apart.
- A later sweep re-reports the key only in a process that has not reported it yet.
  A winner of the `super_fetch:reaper` lock that already holds the key in its set
  stays quiet.
- The **cluster-wide sweep lock does not suppress the warning.** It decides who
  sweeps, not who has already said it.
- A restart starts over: the memory does not survive the process, so the key is
  reported again after every restart.

The message says so itself:

> Reported once per process: every worker that sees the key logs it for itself,
> and it is reported again after a restart.

So "one identical line per worker pid" — one per worker serving that queue — is
the expected shape of this warning, not evidence that the fleet is suppressing
it. The set is also bounded (1000 keys); past that it is cleared, and keys can
be reported again inside the same process. The step-by-step recovery is in the
incident runbook's
[orphaned private lists](runbook.md#orphaned-private-lists) entry.

### What reclaim actually does

Job by job, tail-to-tail:

```
LINDEX  queue:default|dead-host|9182|b2c3d4e5f6a1|0  -1
RPUSH   queue:default  <job>
RPOP    queue:default|dead-host|9182|b2c3d4e5f6a1|0
```

That is one script, with the effect of `LMOVE ... RIGHT RIGHT`, and it pushes first:
Dragonfly near `maxmemory` answers an `LMOVE` between shards having popped the job and
dropped the push, and a refused write must leave the job where it was.

The move happens **before** the poison-pill check, so a crash mid-drain leaves
the job safely on the public queue — at-least-once, never lost.

### A live worker's own private list

The reaper never touches a live owner's list, and a live owner only settles the
jobs its threads know about. Two things leave a payload there that no thread
knows about:

- **A claim whose reply was lost.** Redis applied the `LMOVE`, then the
  connection went: a Redis restart, a stall past the 2.5s read timeout, a reset
  socket. The client re-sends and claims another job. That is up to one job per
  processor thread per incident, and nothing reports it.
- **A job that failed while Redis was down**, where the retry booking and the
  requeue both raised. The requeue failure is logged at ERROR.

So every worker checks its own lists on every reaper tick. A payload in the list
that no thread's claim and no pending ACK accounts for is suspect. Seen stranded
again at least 30s later, it goes back to its public queue through the same
guarded script as a shutdown requeue, and through the same
[poison-pill](#poison-pills) count as a reclaim. **Such a job runs up to two
reaper intervals late (2 minutes at the defaults), and nothing is lost.**

A running job is never touched, however long it runs: its thread holds a claim
for the whole of `perform`. The check costs one `LLEN` per served queue per tick;
it reads payloads only when a list is longer than what its holders account for.

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
- The counter is dropped when the job **acks** — the round trip that removes it
  from its private list carries the `DEL`, so the reset costs no extra round
  trip (it is still a Redis command, one of the three in that pipeline).
  Anything that finishes an attempt counts (a clean run, or a raise that booked
  a retry): the job proved it does not take its worker down. Only reclaims of an
  attempt that never finished accumulate, so unrelated crashes spread across the
  72h window can't dead-set a job that has been completing all along. Because
  [the ACK rides the next fetch](#the-ack-rides-the-next-fetch), a job hard-killed
  after finishing but before its ACK flushed does accrue a recovery; crossing the
  threshold that way needs three such kills on the same `jid` inside 72h, each of
  which is a duplicate execution in its own right.
  The reset needs the jid, which the ACK path takes from the payload it has
  already parsed. A unit of work carrying no jid — a blank one, or a custom
  `config[:fetch_class]` whose unit of work has no jid slot at all — still acks
  normally, it just leaves its counter to expire on the 72h TTL rather than
  clearing it early. Nothing is deleted on a blank jid: the key it would build
  is the bare prefix, which is shared rather than per-job.
- Past `RECOVERY_THRESHOLD` (**3**) recoveries — the 4th orphaning, as in
  Sidekiq Pro — the job is killed into the dead set and
  `LREM`'d back off the public queue so it isn't also re-run.
- The kill fires **death handlers** (`ex` is a
  `Wurk::Middleware::PoisonPill::Poisoned`), so `:death` batch callbacks and
  error services see it like any other exhaustion. Sidekiq Pro doesn't specify
  this either way — see [parity divergences](idea/parity-divergences.md).
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
bumping it; `.clear!(jid)` resets one by hand.

---

## At `maxmemory`

`LMOVE` is a command Redis refuses when full, and Wurk requires `noeviction`. With
nothing else, a backlog that fills Redis would stop every worker from fetching,
and the memory could never come back.

So on an OOM refusal the fetcher claims through a script flagged `allow-oom`, and
the workers keep draining with the limit in place. Still through the private list,
still at-least-once. An error report fires once a minute per fetcher while it
lasts, so watch for `Redis is at maxmemory`.

| While Redis is full | Behaviour |
|---|---|
| Fetch, ACK | Work. Moving a job between lists grows nothing but a small key |
| Retry and dead-set booking from a failing job | Work, through the same flag |
| Reclaiming a dead worker's list | Works, every job on the list. The sweep lock goes through the same flag. The poison-pill count can't be taken: a job moved while Redis is full is not counted |
| Requeue at shutdown, a stranded job put back | Work, through the same flag |
| Dashboard retry or kill | The push is refused and the job goes back to its set, through the same flag |
| Heartbeat | Its write is refused, so a claim also writes the identity hash and moves `beat`: a worker still fetching is not read as dead. A worker with every thread in a long job has no claim to write it with until a thread frees up. Stats and metrics writes are dropped |
| Queues under `global_concurrency` | Not claimed through this path, since it skips the slot ledger |
| Enqueues, scheduling | Still refused: that pressure is what you want producers to feel |

Valkey behaves as Redis does.

Dragonfly compiles no `#!lua` header and reports OOM with a different error, so none
of this path runs there: a full Dragonfly refuses what the table says works. It also
doesn't abort a `MULTI` or a script on the refusal, so every move between two keys
adds before it removes and a refused write leaves the job where it was: requeue,
reclaim, scheduler burial, debounce replacement.

> [!WARNING]
> **Keep a Dragonfly well below `maxmemory`.** Two things stay exposed on a full one
> (seen on 1.34 and 2.0.2). `LMOVE` and `BLMOVE` between shards can pop the job and
> drop the push, returning it to the worker with no private copy. The job still runs,
> but if it then fails with its retry refused, or the process dies, it is lost. And a
> dashboard retry whose push is refused cannot put the entry back.

---

## The reliable scheduler

The default poller (`Wurk::Scheduled::Enq`) claims a batch of due members from the
`retry` and `schedule` sorted sets by rescoring them to a 60s lease, pushes each
through the client, and only then removes it. A crash, an out-of-memory push or a
`kill -9` at any point leaves the member in its set, and it is promoted again once
the lease lapses. The failure mode is a duplicate and a delay of up to 60s, never a
lost job.

`reliable_scheduler!` swaps in `Wurk::Scheduled::ReliableEnq`, which promotes due
jobs in a single atomic Lua script: `ZRANGEBYSCORE` → `SADD queues` →
`LPUSH queue:<name>` → `ZREM`. It is worth having for throughput, about 25x on
Redis, on a large backlog of due jobs. It **skips client middleware**, because the
script writes the queue directly.

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

What gets caught: `RedisClient::ConnectionError` and
`ConnectionPool::TimeoutError` (checkout starvation). `Wurk::RedisPool` retries
first, but only where a replay is provably safe: a connect-phase failure
(`CannotConnectError` / `FailoverError`) gets 3 attempts with exponential
backoff, while a read/write timeout — where the push may already have applied —
raises on the first error rather than risk a duplicate job, and lands in the
buffer straight away. That backoff only runs while the push has landed nothing:
once a queue group is acknowledged the pool stops replaying the block whatever
the error, so a push that dies partway can never double the group it already
delivered.

**During an outage.** The first failed push pays the connection backoff and opens
a circuit for that Redis. Later pushes buffer without touching the socket, so they
do not block. A drainer thread, started on that first failure if none is running,
probes the server, replays the buffer and closes the circuit. A circuit closes by
itself after 30s if nothing has renewed it.

**The buffer is process memory.** A clean exit flushes it, bounded at 5s, and logs an ERROR for anything it could not deliver. A SIGKILL or an OOM kill loses whatever is still buffered, and a full buffer drops the oldest job by default. Producers no longer wait out the outage, so the default 1000 entries fill quickly: raise `reliable_push_buffer`, or set `reliable_push_overflow = :raise`, if an outage must not drop work.

**Flush behavior.** Every buffered payload remembers the Redis pool it was
headed for, so a sharded `Client.via(pool)` backlog never replays into another
shard; the drainer drains each origin in turn. With the circuit closed, a `push` /
`push_bulk` also drains the entries bound for its own pool oldest-first before
pushing the new job; while it is open, pushes do not drain. Draining stops at the first transient
failure and un-shifts the payload back to the head, so order is preserved and
the same job is retried next time. Non-transient errors (OOM, LOADING, READONLY)
also restore the payload before propagating, so a recovering-but-not-ready Redis
can't silently eat one buffered job per tick. Each drained payload increments
statsd `sidekiq.jobs.recovered.push`.

A producer that goes quiet mid-outage is covered too, because the drainer replays
on its own. You can start it up front or set its interval (a Wurk extension beyond
the Pro spec):

```ruby
Wurk::Client.reliable_push_drainer(interval: 2.0)   # implies reliable_push!
Wurk::Client.reliable_push_drainer_running?         # => true
Wurk::Client.reliable_push_drainer_stop!
```

**What is not buffered.** Payloads carrying a `bid` — batch creation and
batch-context pushes. Those re-raise, because the batch Lua has atomic counter
side effects that can't be safely replayed. In a mixed `push_bulk`, the bidless
payloads buffer and the batched ones raise.

Also not buffered: payloads Redis already accepted. A push is more than one
round trip — one pipeline per destination queue, then the batched `BATCH_PUSH`
pipeline — so a connection that drops partway leaves some of the payload set
written. Wurk buffers only the groups it has no reply for; a job already in
`queue:<name>` is never replayed on top of itself. The one group in flight when
the socket dropped *is* buffered, because a lost reply is indistinguishable from
a lost command — so that group is at-least-once and may produce a duplicate
job. Sidekiq's own contract is at-least-once and `JobRetry` re-runs jobs anyway;
make jobs idempotent.

### The durability caveat

**The buffer is in-memory and per-process. If the process dies, every buffered
job is gone.** Not written to Redis, not written to disk, not recoverable, not
logged as a payload you can replay.

### Fork semantics

The buffer, its mutexes, and its background drainer are process-global state.
A `fork()` — the Swarm booting children, or a preloading app server like Puma
or Unicorn spawning workers — copies all of it into the child by value: the
same buffered payloads, a drainer thread that did not survive the fork, and
mutexes that could still be held mid-critical-section at the moment of fork.

Wurk resets that state on every fork path it can see, via
`Wurk::Client::Buffered.reset_after_fork!`:

- A `Process._fork` hook (`lib/wurk/client/buffered.rb`), registered at
  require time, fires in every child regardless of how the fork happened —
  this is what catches a preloading app server's own fork, which Wurk's swarm
  code never runs through.
- `Swarm::ChildBoot#reconnect_after_fork` (`lib/wurk/swarm/child_boot.rb`)
  also calls it explicitly, right after `@config.reset_redis_pools!` and
  before `validate_redis!`. Whichever of the two runs first wins; a pid guard
  makes the second call a no-op.

What the reset does, in a child:

- **Drops the inherited buffer.** The child does not replay the payloads it
  woke up holding. The parent still has the same buffer and will replay it on
  its own next push — if the child replayed too, every buffered job would
  enqueue `(children + 1)×` times. Only the parent that originally buffered a
  job ever replays it.
- **Rebuilds both mutexes** (`@install_mutex`, `@buffer_mutex`) as fresh
  objects rather than reusing the inherited ones. MRI abandons a mutex whose
  owning thread didn't survive the fork, but that's an implementation detail,
  not a documented guarantee, and it does not cover a fork taken while a
  *different* thread's critical section was still open — the child would
  inherit that mutex still locked, and its first buffered `push` (which drains
  under the lock before pushing) would hang forever. Fresh allocations are
  immune regardless.
- **Drops the drainer without stopping it.** `Drainer#stop` synchronizes on
  the drainer's own lock, which carries the same inherited-mutex hazard as
  above, so the inherited drainer is discarded rather than shut down. If the
  parent had one running (`interval` was set), the child gets an equivalent
  fresh drainer on its own interval, so a child that keeps buffering jobs
  still flushes them.

Net effect: after a fork, each process — parent and every child — owns an
independent buffer, drainer, and pair of mutexes, and only ever replays jobs
it buffered itself.

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
  MyJob.perform_bulk(ids.map { |id| [id] })
rescue Wurk::Client::Buffered::Overflow => e
  Outbox.insert_all(e.payloads.map { |p| { payload: p } })   # every undelivered job
end
```

`:raise` fills the remaining capacity first, then raises **once**. `e.payloads`
carries everything that push failed to deliver — the tail of a bulk push that
didn't fit, plus any batched payloads in the same call (those never buffer). The
payloads that *did* fit stay in the buffer and replay normally, so no job is
both buffered and reported. `e.cause` is the underlying connection error.

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
| `config.reliable_scheduler!` | **A real call.** Swaps `scheduled_enq` to the atomic promoter, which promotes more per round trip and skips client middleware. Idempotent. |
| `Sidekiq::Client.reliable_push!` | **A real call.** Installs the outage buffer. Idempotent. |
| `config.fetch_poll_interval =` | **A real call.** Overrides the 2s `BLMOVE` block timeout. |
| `retry: :reliable` | Accepted; the private-list-until-ack behavior it names is already how every job runs. |

Recovery counter keys and their TTLs, reaper lock names, and statsd metric
names retain the Pro spec's forms — tooling watching `super_fetch:recovered:*`,
`super_fetch:reaper`, or `sidekiq.jobs.poison` needs no naming change.
Private-list names are an intentional exception: Pro specifies
`queue:<public>|<hostname>|<pid>|<index>`, while Wurk writes
`queue:<public>|<host>|<pid>|<nonce>|<index>`. Tooling that assumes Pro's fixed
four-part names must adapt to the nonce-bearing shape. Wurk's reaper still
accepts legacy nonce-free keys; see the [migration window](#reliable-fetch).

### Intentional divergences

Private-list naming, timing, and shutdown queue position deliberately differ
from Pro. The four divergences below are recorded in the
[parity ledger](idea/parity-divergences.md); all retain at-least-once delivery,
and none is behind a flag:

| Divergence | Pro behavior | Wurk behavior | Cost |
|---|---|---|---|
| [Private-list naming](idea/parity-divergences.md#private-list-names-include-a-process-image-nonce) | Four-part `queue:<public>\|<hostname>\|<pid>\|<index>` | Five-part `queue:<public>\|<host>\|<pid>\|<nonce>\|<index>`; legacy keys remain reclaimable | Fixed-four-part parsers must adapt; nonce separates process incarnations, not same-boot pid reuse |
| [ACK timing](#the-ack-rides-the-next-fetch) | `LREM` right after success or retry handling | Same ordering, pipelined with the next fetch; flushed before every idle, quiet, stop, or shutdown | A hard kill can re-run an already-finished job for longer. At-least-once either way |
| [Paused-queue visibility](#fetch-order-and-polling) | `SMEMBERS paused` per fetch pass | Cached 2s per fetcher; in-process pause is immediate | Cross-process pause lands within 2s. Unchanged fleet-wide worst case |
| [Shutdown requeue](#graceful-shutdown) | Whole private list drained to the back of the queue at shutdown | Still-parked jobs moved to the front of the queue at shutdown | None — interrupted work runs next instead of queueing behind the backlog again |

The full argument for each, the conditions they were accepted under, and what
would reverse them: [parity divergences](idea/parity-divergences.md) and
`docs/plans/2026/08/06/101-faster-than-sidekiq/00-semantics-signoff.md`. Job
metrics are batched on the same reasoning — that one is in
[Metrics](metrics.md#write-cadence-and-what-a-hard-kill-costs), since it affects
dashboard counters rather than delivery.

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
disappear within one reaper interval (60s same-host) or the 60-135s of a
cross-host reclaim. If it doesn't, check that reaper threads are actually
running and that no process is holding the `super_fetch:reaper` lock without
sweeping. The step-by-step version, including how to move a list back by hand
safely, is the [orphaned private lists](runbook.md#orphaned-private-lists)
runbook entry.

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

See also the [incident runbook](runbook.md) — symptom → check → fix for the
failure modes this page describes, from a stuck queue to a rollback to Sidekiq.

- [Deployment](deployment.md) — signals, rolling restarts, and what a graceful
  drain actually waits for.
- [Running Wurk](running.md) — process topology, queues, and concurrency.
- [Migrating from Sidekiq](migrate-from-sidekiq.md) — what changes on the
  one-line gem swap, and the
  [production cutover](migrate-from-sidekiq.md#9-production-cutover) procedure.
