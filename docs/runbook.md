# Incident runbook

What to do when Wurk misbehaves in production. Each entry goes **symptom → check →
fix**, using three tools you already have: the dashboard, `bin/rails runner` (the
`Sidekiq::*` API answers under Wurk, so these snippets also work against a Sidekiq
fleet), and `redis-cli`. The commands assume `redis-cli -u "$REDIS_URL"`.

How the guarantees behind these steps work (reliable fetch, the reaper, the
scheduler, at-least-once) is in [reliability](reliability.md). Signals, probes and
rolling restarts are in [deployment](deployment.md).

| Incident | Jump to |
|---|---|
| One queue grows and nothing drains it | [Stuck queue](#stuck-queue) |
| `queue:*\|*` keys pile up, jobs seem to vanish | [Orphaned private lists](#orphaned-private-lists) |
| Jobs run, but late | [Latency spike](#latency-spike) |
| Periodic (cron) jobs stopped firing | [Leader stuck](#leader-stuck-periodic-not-firing) |
| Dead set fills with `Poisoned`, workers keep dying | [Poison-job storm](#poison-job-storm) |
| Redis restarted, failed over, or is unreachable | [Redis failover](#redis-failover) |
| Worker or Redis memory keeps climbing | [Memory growth](#memory-growth) |
| A batch never fires `:success` or `:complete` | [Batch never completes](#batch-never-completes) |
| The dead set keeps growing | [Dead set growth](#dead-set-growth) |
| You need to go back to Sidekiq | [Rollback to Sidekiq](#rollback-to-sidekiq) |

A quick overall health read before you start:

```bash
bin/rails runner 's = Sidekiq::Stats.new; p(enqueued: s.enqueued, busy: s.workers_size, retry: s.retry_size, dead: s.dead_size, processes: s.processes_size)'
```

---

## Stuck queue

**Symptom.** One queue's size climbs on the dashboard's **Queues** page while other
queues drain normally. Its latency keeps rising.

**Check.**

1. Is it paused? The **Queues** page shows a paused badge; or
   `redis-cli SISMEMBER paused <queue>` answers `1`.
2. Does any running process listen to it?

   ```bash
   bin/rails runner 'Sidekiq::ProcessSet.new.each { |p| puts "#{p.identity} quiet=#{p.stopping?} #{p["queues"].inspect}" }'
   ```

   A queue missing from every list, or listed only on processes that report
   `quiet=true`, has no consumer. Quiet (`TSTP`) is one-way: a quieted process never
   resumes fetching.
3. Is a cap holding it? A `config.global_concurrency` entry for the queue, or a
   limiter in the job, admits only so many at once ([rate limiting](rate-limiting.md)).
   The **Busy** page shows how many of that queue's jobs are running right now.
4. Is it starved by ordering? With strict queue ordering, a lower queue only runs
   when every queue listed before it is empty.

**Fix.**

- Paused: `bin/rails runner 'Sidekiq::Queue.new("<queue>").unpause!'`, or **Unpause**
  on the dashboard.
- No consumer: add the queue to `config.queues` (or the topology slot that should own
  it) and roll the workers. Quieted processes: stop them with `TERM` and let the
  supervisor start fresh ones.
- Capped: raise the cap if it is wrong. If the in-flight count looks stuck at the cap
  with nothing on **Busy**, treat it as a bug and open an issue with the queue's
  settings.
- Starved: use weighted queues (`[["critical", 5], ["default", 1]]`) or give the queue
  its own topology slot.

## Orphaned private lists

**Symptom.** `redis-cli --scan --pattern 'queue:*|*' | wc -l` stays well above
processes × queues, or jobs that were running when a worker died never ran again.

**Check.** List the private lists and their owners:

```bash
redis-cli --scan --pattern 'queue:*|*' | while read -r k; do echo "$k len=$(redis-cli LLEN "$k")"; done
redis-cli SMEMBERS processes
```

A Wurk list is named `queue:<q>|<host>|<pid>|<nonce>|<index>`, and its owner's
process key is `<host>:<pid>:<nonce>`. `redis-cli EXISTS <host>:<pid>:<nonce>`
answering `0` means the owner is no longer heartbeating. A Sidekiq Pro list is
`queue:<q>|<host>|<pid>|<index>`.

The reaper reclaims a dead owner's list within one sweep (every 60s per process,
plus a full keyspace scan hourly), once the owner's heartbeat (60s TTL) has expired.
Only one process sweeps at a time: `redis-cli TTL super_fetch:reaper` shows the
current lock.

**Fix.**

- A list whose owner is alive is not orphaned. It holds that process's in-flight
  jobs; leave it alone.
- A dead owner's list that is still there several minutes after the heartbeat
  expired: check the worker logs for reaper errors, and check the name parses as one
  of the two shapes above. Names in any other shape are skipped by the reaper.
- To move a list back by hand, first be **certain the owner is dead** (no heartbeat,
  and no process with that pid on that host). Moving a live process's list runs its
  in-flight jobs twice.

  ```bash
  k='queue:default|web-1|4242|3f9c0e1a|0'      # the orphaned list
  q="${k%%|*}"
  while [ -n "$(redis-cli LMOVE "$k" "$q" RIGHT RIGHT)" ]; do :; done
  ```

- A steady stream of new orphans means workers are dying with jobs in flight
  (OOM kills, segfaults, `SIGKILL` before the shutdown timeout). Fix that cause; see
  [memory growth](#memory-growth) and [poison-job storm](#poison-job-storm).

## Latency spike

**Symptom.** Queue latency climbs on **Queues** and the metrics charts, but jobs are
still completing.

**Check.**

1. Saturation: compare running jobs with capacity.

   ```bash
   bin/rails runner 'ps = Sidekiq::ProcessSet.new; puts "busy=#{Sidekiq::Workers.new.size} capacity=#{ps.total_concurrency}"'
   ```

   Busy at or near capacity means you are out of workers.
2. Slow jobs: the **Busy** page lists what is running and for how long. A handful of
   long jobs pinning every thread looks like saturation.
3. Database: `ActiveRecord::ConnectionTimeoutError` in the logs means the DB pool is
   smaller than `concurrency` ([migration §2](migrate-from-sidekiq.md#2-concurrency-vs-parallelism-read-this)).
4. Redis: `redis-cli --latency` (sub-millisecond is normal) and `redis-cli SLOWLOG GET 20`.
5. Caps: a `global_concurrency` entry or a limiter deliberately holds a queue back.

**Fix.**

- Saturated: add workers (`WURK_COUNT`, `concurrency`, or more hosts), then recheck the
  DB-pool and memory arithmetic. Move slow work onto its own queue and topology slot so
  it cannot hold up fast work.
- Pause a non-critical queue to free capacity while you scale.
- Redis slow: look for big keys (`redis-cli --bigkeys`) and expensive commands in the
  slowlog. Dashboard pages that page through huge sets are visible there too.

## Leader stuck (periodic not firing)

**Symptom.** The **Cron** tab shows **last fire** falling behind the schedule.

**Check.**

```bash
redis-cli GET dear-leader        # identity of the current leader, host:pid:nonce
redis-cli TTL dear-leader        # 0–30 while a leader renews it
redis-cli EXISTS "$(redis-cli GET dear-leader)"   # 1 if that process still heartbeats
```

- No leader (`nil`): every process may be opted out with `WURK_LEADER=false` /
  `SIDEKIQ_LEADER=false`. Followers re-check every 60s, so a new leader can take up to
  a minute.
- Leader identity not heartbeating: it died without releasing the lock. The 30s TTL
  frees it.
- Leader healthy, one loop silent: is the loop paused on the **Cron** tab? Read its
  marks with `redis-cli HGETALL loops:<lid>`: `nf` is the next fire as epoch seconds.
  An empty `nf` means the schedule can never match again (`0 0 30 2 *`).
- Logs: `[cron] missed tick` (a fire more than 90s late was skipped) and
  `[cron] fire lost` (the push failed after the slot was claimed).

**Fix.**

- Opted out everywhere: let at least one pool campaign (unset `WURK_LEADER`).
- Lock held with no TTL (`TTL` answers `-1`, which Wurk never writes): `redis-cli DEL dear-leader`.
- Paused: **Unpause** on the **Cron** tab.
- Fire a missed occurrence by hand: **Enqueue** on the **Cron** tab, or
  `bin/rails runner 'Wurk::Cron.fire!("<lid>")'` (also advances the fire marks).
- A quieted leader keeps firing cron; only a full stop hands leadership over. That is
  expected, not a fault.

## Poison-job storm

**Symptom.** The dead set climbs with `Wurk::Middleware::PoisonPill::Poisoned`
errors, the `sidekiq.jobs.poison` statsd counter is non-zero, and the logs show
swarm children exiting and being respawned.

A job is poisoned when three attempts in 72h never acknowledged because the process
running it died (the counter is `super_fetch:recovered:<jid>`). Wurk then kills it
to the dead set instead of letting it take down a fourth worker.

**Check.**

```bash
bin/rails runner 'p Sidekiq::DeadSet.new.map { |e| [e.klass, e["error_class"]] }.tally'
```

Then find out why the worker died: OOM kills (`dmesg`, container events), native
crashes (segfault output in the worker log), or a job that blocks past the shutdown
timeout and gets `SIGKILL`ed on every deploy.

**Fix.**

1. Stop the bleeding: pause the queue the class runs on, or deploy a guard that
   returns early for the offending input.
2. Fix the cause (memory, native extension, unbounded work).
3. Retry the dead jobs once fixed:

   ```bash
   bin/rails runner 'Sidekiq::DeadSet.new.select { |e| e.klass == "<JobClass>" }.each(&:retry)'
   ```

A poison kill fires death handlers, so a poisoned job's batch records a death rather
than hanging.

## Redis failover

**Symptom.** Errors such as `RedisClient::CannotConnectError`, `READONLY`, or
`LOADING` in the logs; `/ready` answers `503` with `"reason":"redis unreachable"`.

**What Wurk does on its own.** Each process keeps running and reconnects: a dropped
socket re-sends the one in-flight command once (as Sidekiq does), and the pool
rebuilds connections. In-flight jobs keep their place in their private lists, so a
process that dies during the outage loses nothing. Enqueues raise during the outage
unless you installed `Wurk::Client.reliable_push!`, which buffers them in memory and
replays them when Redis returns ([reliability](reliability.md)).

**Check.**

1. `redis-cli PING` from a worker host, and `redis-cli INFO replication` (`role:master`).
2. With Sentinel: `redis-cli -p 26379 SENTINEL get-master-addr-by-name <name>`.
3. Persistent `READONLY` errors mean clients are still talking to a node that is now a
   replica. That happens with a static URL pointing at one node rather than at
   Sentinel or a failover-aware endpoint.

**Fix.**

- Transient blip: nothing. Confirm `/ready` goes green and queues drain.
- Clients stuck on the old primary: point `config.redis` at Sentinel (`sentinels:` +
  `master_name:`) or the provider's failover endpoint, then do a rolling restart
  (`kill -USR1 <wurkswarm parent pid>`).
- After a failover that lost writes (asynchronous replication), recent enqueues may be
  gone. Check the upstream system of record for work that never ran.
- Supported Redis topologies and providers: [deployment](deployment.md).

## Memory growth

**Symptom.** Worker RSS climbs until the container is OOM-killed, or Redis
`used_memory` keeps rising.

**Check (workers).** The **Busy** page shows RSS per process. Correlate growth with
the job classes running at the time.

**Fix (workers).**

- Turn on recycling: `SIDEKIQ_MAXMEM_MB=<limit>` (or `config.memory_limit_mb`). A
  child past the limit is replaced gracefully: replacement first, then a drain of the
  old one ([deployment](deployment.md#memory-based-auto-restart)). Linux only.
- An immediate reset of every child without dropping work:
  `kill -USR1 <wurkswarm parent pid>` (rolling restart).
- Find the job that grows memory and fix it; recycling hides a leak, it does not fix it.

**Check (Redis).**

```bash
redis-cli INFO memory | grep -E 'used_memory_human|maxmemory_human|maxmemory_policy'
redis-cli --bigkeys
for p in 'queue:*' 'b-*' 'status:*' 'unique:*' 'uniquejobs:*' 'cron_job*'; do
  printf '%-14s %s\n' "$p" "$(redis-cli --scan --pattern "$p" | wc -l)"
done
```

**Fix (Redis).**

- A queue with millions of entries is a backlog, not a leak: see
  [latency spike](#latency-spike).
- The dead set is bounded (10,000 jobs or 180 days by default); see
  [dead set growth](#dead-set-growth) if it is the big key.
- Batch keys expire 30 days after creation, 24h after `:success`.
- Leftovers from a migration (`uniquejobs:*`, `cron_job*`) are safe to delete once you
  are past your rollback window ([migration guide](migrate-from-sidekiq.md#6-third-party-gem-mappings)).
- Keep `maxmemory-policy noeviction`. An evicting policy turns memory pressure into
  silently lost jobs.

## Batch never completes

**Symptom.** A batch stays below 100% on the **Batches** page; `:success` (or
`:complete`) never fires.

**Check.**

```bash
bin/rails runner 's = Sidekiq::Batch::Status.new("<bid>"); p(total: s.total, pending: s.pending, failures: s.failures, invalidated: s.invalidated?)'
redis-cli SMEMBERS b-<bid>-jids          # jids still outstanding
redis-cli SMEMBERS b-<bid>-failed        # jids currently failing
redis-cli SMEMBERS b-<bid>-died          # jids that went to the dead set
```

Read the result against how batches count ([batches](batches.md#failure-handling)):

- Jids in `failed`: the job is still retrying. The batch waits for the retry cycle.
- Jids in `died`: the batch fires `:complete` but never `:success`, by design.
- A `hold:` member in `b-<bid>-jids`: the `jobs { }` block that created the batch
  raised. Nothing after the exception was enqueued, so the batch never fires, by
  design.
- `invalidated: true`: jobs short-circuit without running; the batch completes as they
  drain.
- Outstanding jids with no job anywhere (`bin/rails runner 'p Sidekiq::Queue.all.sum { |q| q.find_job("<jid>") ? 1 : 0 }'`
  plus the **Retries**, **Scheduled** and **Dead** search): the job was lost outside
  Wurk's control (deleted by hand, lost in a Redis failover).

**Fix.**

- Dead jobs: fix the cause, then retry them from **Dead**. When the died set empties,
  `:success` becomes reachable again.
- A batch whose creating block raised: re-create the work in a new batch. The stuck
  batch's keys expire on their own after 30 days.
- Lost jobs: re-enqueue them inside the batch (`batch.jobs { … }` on the existing
  bid) so their acknowledgement drains the count.

## Dead set growth

**Symptom.** The **Dead** count rises steadily.

**Check.** Group by class and error:

```bash
bin/rails runner 'p Sidekiq::DeadSet.new.map { |e| [e.klass, e["error_class"]] }.tally.sort_by { -_2 }.first(20)'
```

Error classes that point at Wurk mechanics rather than your code:

| Error | Means | See |
|---|---|---|
| `Wurk::Middleware::PoisonPill::Poisoned` | Worker died three times running the job | [Poison-job storm](#poison-job-storm) |
| Limiter over-limit error, message starting `rate_limited:` | Limiter reschedule cap exhausted | [rate limiting](rate-limiting.md) |
| `Wurk::Encryption::DecryptionError` | Missing or wrong encryption key | [encryption](encryption.md) |

Anything else is your job raising until its retries ran out.

**Fix.** Fix the cause, then retry in bulk (dashboard **Dead → Retry all**, or filter
first):

```bash
bin/rails runner 'Sidekiq::DeadSet.new.select { |e| e["error_class"] == "<Error>" }.each(&:retry)'
```

The set trims itself at `dead_max_jobs` (10,000) and `dead_timeout_in_seconds`
(180 days), so unbounded growth is not possible, but past that cap the oldest dead
jobs are discarded. Alert on growth before you reach it.

## Rollback to Sidekiq

**When.** Wurk has a problem you cannot fix forward fast enough.

**Procedure.** It is a drain, never a mix: quiet Wurk, wait for `busy=0`, stop it,
**confirm Wurk's private lists are empty** (stock Sidekiq never reclaims their
five-segment names), then start Sidekiq. The full checklist, with every command and
what does not carry back, is
[migration §9.5](migrate-from-sidekiq.md#95-rollback).

---

## Related

- [Reliability](reliability.md) — the delivery guarantee these steps rely on.
- [Deployment](deployment.md) — signals, probes, rolling restarts, memory limits.
- [Migrating from Sidekiq](migrate-from-sidekiq.md#9-production-cutover) — the
  production cutover and rollback procedure.
- [Metrics](metrics.md) — what to graph and alert on.
