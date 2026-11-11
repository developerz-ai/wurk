# 08 — Observability: what an operator cannot see today

> Part of [`overview.md`](overview.md). Depends on: none (O6 after [`05`](05-memory.md) M4).

Exists: Prometheus families in `lib/wurk/metrics/prometheus.rb` (queue size/latency/consumers, busy, processed/failed/retry/dead/scheduled, `wurk_fetch_errors_total`, `wurk_reaper_reclaimed_total`, per-process heartbeat age/rss/quiet, swarm children expected/fresh, leader, `redis_up`); `Metrics::ProcessCounters` counts only `fetch_errors` + `reaper_reclaimed`; statsd; OTel traces (`docs/telemetry.md`); `examples/kubernetes/prometheus-rule.yaml`. Adopter fact: **no adopter exports any of it** (tesote alerts file: "queue depth needs the app to export metrics first — none does today").

Rule: no new Redis key and no new field in Sidekiq-shaped hashes without a decision. In-process counters → existing export paths. An additive heartbeat `info` field follows the `host_facts` precedent (`lib/wurk/heartbeat.rb:264-273`) and needs H9.

## Files to change

| ID | Where | Missing | Change |
|---|---|---|---|
| O1 | `lib/wurk/swarm.rb:565-575,651-656`, `lib/wurk/metrics/process_counters.rb`, `lib/wurk/metrics/prometheus.rb` | Child respawns, crash streak, memory recycles — logs only. | Parent counters → `wurk_swarm_child_restarts_total{reason=crash\|memory\|rolling}`, `wurk_swarm_crash_streak`. Parent has no heartbeat → export via the health listener `/metrics` of the parent when configured, else periodic INFO summary line. |
| O2 | `lib/wurk/heartbeat.rb` (`beat_hash_args` writes `rtt_us` already), `prometheus.rb:68` | Redis RTT not exported. | `wurk_process_redis_rtt_seconds`. |
| O3 | `lib/wurk/redis_pool.rb:367` (`notify_error` → optional `on_error` only) | Pool checkout timeouts invisible (hiscore: pool < threads killed every job; `wurk.log` grew to 3 GB of timeouts). | `ProcessCounters.increment(:pool_timeouts)` + `wurk_redis_pool_timeouts_total`; coalesce the log line (existing `ErrorCoalescer`) so a starved pool cannot write GBs. |
| O4 | `lib/wurk/processor.rb:466` (`WORK_STATE.run_at`), `lib/wurk/swarm.rb:351` (liveness = heartbeat only) | Process heartbeats but all processors wedged → looks healthy. | `wurk_process_oldest_job_age_seconds` from `WORK_STATE`; optional `wurk health --max-job-age=<s>` flag (off by default). |
| O5 | `lib/wurk/middleware/poison_pill.rb` (statsd only), `lib/wurk/fetcher/self_reconcile.rb`, `lib/wurk/client/buffered.rb`, `lib/wurk/scheduled.rb` | Poison kills, self-reconcile moves, client-buffer drops, scheduler promotion lag: statsd/log only. | Counters/gauge in Prometheus: `wurk_poison_kills_total`, `wurk_self_reconcile_moves_total`, `wurk_client_buffer_dropped_total`, `wurk_scheduled_lag_seconds` (now − oldest due score, leader-only). |
| O6 | `lib/wurk/health.rb` (`/metrics` on the health listener), `prometheus.rb` | No GC/heap metrics; swarm parent memory invisible; no PSS. | Health listener `/metrics` adds own-process `GC.stat` subset (`heap_live_slots`, `major_gc_count`, `malloc_increase_bytes`) + RSS (+PSS when M4 metric = pss). Parent logs own + per-child RSS every N minutes at INFO. |
| O7 | `lib/wurk/fetcher/reliable.rb` | Fetch latency / empty-poll rate unknown — needed to judge A3. | In-process histogram of `walk` duration + empty-poll counter, flushed through `Metrics::Flusher` to statsd/Prometheus only (no Redis write). Must not add a per-job allocation (G1 budget). |
| O8 | `docs/metrics.md`, `docs/runbook.md`, `examples/kubernetes/prometheus-rule.yaml`, `docs/migrate-from-sidekiq.md` checklist | Adoption gap: metrics exist, nobody scrapes. | Migration checklist step "expose `/metrics`"; alert rules for new families (restarts, pool timeouts, oldest job age, scheduled lag, unconsumed queue); runbook entry per alert. |
| O9 | `lib/wurk/rails_boot.rb`, `lib/wurk/cli.rb` boot banner | Role confusion (see B1, B8). | Covered by B1/B8 — listed for traceability only. |

## Steps
1. PR-a: O1–O5 counters + Prometheus families + unit tests (pattern: `test/unit/metrics_prometheus_test.rb`).
2. PR-b: O6 + O7 (allocation-neutral; run G1).
3. PR-c: O8 docs/examples.
4. Naming: follow existing `wurk_*` families; document every family in `docs/metrics.md` in the same PR.

## Tests
- Unit per family (value appears in scrape output with expected labels).
- O3: integration — size-1 pool + contention → counter > 0, log lines coalesced (count bounded).
- O4: unit — job running 120s → gauge ≥ 120; `wurk health --max-job-age=60` exits non-zero.
- `bin/check`; G1 budget unchanged after O7.

## Done when
- Each of: child crash loop, memory recycle storm, starved pool, wedged processors, scheduler lag, poison kill — has a metric, an example alert rule, and a runbook entry.
- Scrape output documented family-by-family in `docs/metrics.md`.
