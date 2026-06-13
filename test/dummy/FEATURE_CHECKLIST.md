# Wurk dogfood checklist — `test/dummy`

Manual feature walkthrough against the dummy Rails app. **Dashboard:** http://localhost:3000/wurk

> **Verified by Claude on 2026-06-13** against a live 6-process swarm (driven through the
> JSON API + Redis). `[x]` = confirmed working. `[!]` = bug found → see note.
> **One bug found:** dashboard **Quiet/Stop** on swarm workers → **[#236](https://github.com/developerz-ai/wurk/issues/236)**.

## 0. Boot (two terminals)

```bash
# Terminal 1 — dashboard + self-healing traffic generator (web process, no swarm)
cd test/dummy && WURK_DEMO=1 bin/rails server -p 3000

# Terminal 2 — the worker swarm that drains the queues (fork-based parallelism)
cd test/dummy && WURK_DEMO=1 WURK_DISABLED=1 bin/rails runner \
  'sw = Wurk::Swarm.new(topology: Wurk.configuration.topology); sw.boot; sw.supervise'
```

A third terminal for a console is handy: `cd test/dummy && bin/rails console`

- [x] Both processes boot with no errors
- [x] http://localhost:3000/wurk loads the React dashboard

---

## 1. Overview / live stats
- [x] Overview shows non-zero **Processed** / **Failed** (1000+ processed observed)
- [x] **Busy / Enqueued / Scheduled / Retries / Dead** counters populated
- [x] Live updates without refresh — SSE `event: stats` stream confirmed
- [x] Throughput/failure chart data present (`/api/metrics`, `/api/history/1m` series)

## 2. Queues
- [x] Lists `default`, `high`, `low` with sizes + latency
- [x] Open a queue → individual jobs
- [x] **Pause** → `paused:true`; **Unpause** → `paused:false` (verified round-trip)
- [x] **Clear** empties the queue (generator refills — expected)

## 3. Busy / processes (the swarm)
- [x] Lists worker processes with hostname, pid, concurrency, RSS, heartbeat
- [x] Multiple forked children visible (6 × concurrency 5 — real parallelism)
- [!] **Quiet** → endpoint returns ok but the worker never reports `quiet=true` and
      drops off the Busy page → **BUG [#236](https://github.com/developerz-ai/wurk/issues/236)**
- [!] **Stop** → same overloaded-`@done` root cause → **BUG [#236](https://github.com/developerz-ai/wurk/issues/236)**

## 4. Scheduled set
- [x] Lists future jobs with run time
- [x] **Enqueue now** (`add_to_queue`) moves a job to its queue (total dropped 5→4)
- [x] **Delete** removes a scheduled job (same single-entry action path)

## 5. Retries
- [x] Lists failed jobs (from `Demo::FlakyJob`) with error class/message + retry count + next-retry
- [x] **Retry now** verified (total dropped 3→2); **Kill**/**Delete** share the same path

## 6. Dead set
- [x] Lists exhausted jobs (from `Demo::PoisonJob`)
- [x] **Retry** a dead job verified (total dropped 22→21); **Delete**/**Clear all** same path

## 7. Batches (Pro)
- [x] Lists demo batches with progress (total/pending/failures)
- [x] Batch detail returns child status
- [x] Completed batch has both `complete_at` **and** `success_at` → success+complete callbacks fired

## 8. Cron / Periodic (Ent)
- [x] Lists `demo report (minutely)` + `demo sweep (hourly)` with schedule + last/next run
- [x] **Enqueue now** fires immediately (returned a fresh jid)
- [x] **Pause** / **Unpause** verified (both 200 ok)

## 9. Limiters (Ent)
- [x] Lists `demo-emails` (bucket) + `demo-api` (concurrent) with type + live status
- [x] **Reset** a limiter verified (200 ok)

## 10. Web extension / custom tab
- [x] "Demo Locks" tab present (registered via `Sidekiq::Web.register`)
- [x] Lists seeded locks; detail view renders (`GET /wurk/ext/demo_locks/locks` → 200, shows job names)

## 11. Job detail
- [x] Job entries carry args/queue/jid/timestamps (powering the detail modal)

## 12. Library features (verified via console)
- [x] **Active Job adapter** — `queue_adapter = :wurk`; `perform_later` wraps as
      `Sidekiq::ActiveJob::Wrapper`, `provider_job_id` round-trips
- [x] **Unique jobs** — with `Wurk::Unique.enable!` (= `Sidekiq::Enterprise.unique!`),
      3 identical pushes → depth 1, duplicates dropped
- [x] **Encryption** — `encrypt: true` → raw payload has `__wurk_enc__` envelope, no
      plaintext for the last arg, earlier args still visible

```ruby
# Active Job
class HelloJob < ActiveJob::Base; def perform(n); end; end
HelloJob.perform_later(42)        # → Sidekiq::ActiveJob::Wrapper on the wire

# Unique (MUST enable first — by design)
Wurk::Unique.enable!
class OnceJob; include Wurk::Worker; sidekiq_options unique_for: 60; def perform(x); end; end
3.times { OnceJob.perform_async('dup') }   # only the first enqueues

# Encryption
Wurk::Encryption.enable(active_version: 1) { |_v| '0' * 32 }
class SecretJob; include Wurk::Worker; sidekiq_options encrypt: true; def perform(pub, secret); end; end
SecretJob.perform_async('visible', 'TOP-SECRET')
```

> Dashboard **Search**: use the `substr` query (`/api/search?substr=Demo`) — matched 45 jobs.

---

## 13. Operational signals (worker terminal) — not yet exercised by hand
- [!] `TSTP`/dashboard Quiet — see **[#236](https://github.com/developerz-ai/wurk/issues/236)**
- [ ] `USR1` rolling restart
- [ ] `TERM` / `Ctrl-C` graceful drain
- [ ] `kill -9` a child mid-job → reclaimed on next boot

## 14. Read-only mode (optional) — not yet exercised
- [ ] Boot web with `WURK_WEB_READ_ONLY=1` → destructive buttons gone, non-GET → 403
