# 11 — Observability + ops kit

> Part of [`overview.md`](overview.md). Depends on: [`03`](03-boot-guards-preflight.md) G5 (gauge name). 2 PRs (O1–O7 · K1–K5).

Exists today: `/metrics` families from the Health server (`wurk_process_*`, `wurk_queue_*`, `wurk_swarm_children_{expected,fresh}`, `wurk_reaper_reclaimed_total`, `wurk_fetch_errors_total`), statsd, OTel traces, `examples/kubernetes/prometheus-rule.yaml`. No adopter scrapes it (`tesote/infrastructure/platform/observability/config/alerts.yml:1392-1393`: "none does today").

## Files to change
| ID | Where | Operator cannot see | Change |
|---|---|---|---|
| O1 | `lib/wurk/swarm.rb:565-576,651-656` (log-only); `lib/wurk/metrics/process_counters.rb` | Child restarts, crash streak, memory recycles | Parent-side counters → `wurk_swarm_child_restarts_total{reason=crash\|recycle\|liveness\|rolling}`, `wurk_swarm_crash_streak`. Parent publishes through its existing heartbeat/health path; no new Redis key unless one already carries parent state — check `lib/wurk/swarm/` first; if a key is needed, it is Wurk-only + TTL'd and listed in `docs/compatibility.md`. |
| O2 | `lib/wurk/heartbeat.rb:198` (`rtt_us` already measured) | Redis RTT | Export `wurk_process_redis_rtt_seconds`. |
| O3 | `lib/wurk/redis_pool.rb:165-176,367` | Pool exhaustion | `wurk_redis_pool_checkout_timeouts_total{pool}` + `available` gauge. |
| O4 | `ProcessCounters` (only `:fetch_errors`, `:reaper_reclaimed`); `poison_pill.rb:194` (statsd only) | Poison kills, self-reconcile vs reaper reclaims (lumped: `reaper.rb` `recovered`), leader transitions, scheduler promotions + lag, client outage-buffer drops | Add counters; split reclaim by source. |
| O5 | `lib/wurk/swarm.rb:752` (Liveness = `child_beats` only); `WORK_STATE` `run_at` | Wedged processors: heartbeat keeps beating, `wurk health` green | `wurk_process_oldest_job_seconds`; `wurk health --max-job-age N` opt-in. |
| O6 | `lib/wurk/heartbeat.rb` `memory_usage_kb`; `swarm.rb:659` | Real per-child memory (RSS counts CoW-shared pages) | Add PSS from `/proc/<pid>/smaps_rollup` as a metric (detail in [`08`](08-memory.md) M1). |
| O7 | `lib/wurk/metrics/accumulator.rb` | Per-class duration on `/metrics` | Expose histogram families from the existing buckets; cap label cardinality (top-N classes + `other`). |
| K1 | new `examples/systemd/wurk.service`, `examples/capistrano/wurk.rake`; `docs/deployment.md` | hiscore hand-rolled a 109-line `lib/capistrano/tasks/wurk.rake` (`RestartSec=1`, no `StartLimit*`) | Ship unit with `StartLimitBurst`/`RestartSec` back-off, `KillSignal=TERM`, `TimeoutStopSec` > `:timeout`, `ExecReload` USR1 for swarm. |
| K2 | `examples/kubernetes/` | 2 apps probe with `ps \| grep` (passes while children crash-loop: `tesote/infrastructure/stacks/sales/__tests__/worker-liveness.test.ts`); legald has no probe | Worker Deployment example: `exec: wurk health` liveness, `terminationGracePeriodSeconds` > `:timeout` + margin, `WURK_COUNT`, PrometheusRule. Migration guide §9 checklist row: "replace `ps` probes with `wurk health`". |
| K3 | `docs/deployment.md` sizing section | `:timeout` vs grace mismatches in every app (sales 400/900, tesote.com 50/60, gringotts 25/900); pool == concurrency with no headroom (tesote.com, legald); one-fork-per-core default surprised 2 apps | One sizing table: processes × threads, Redis pool, AR pool, `:timeout` vs grace. Default `WURK_COUNT` change = human call U5. |
| K4 | `lib/wurk/cron.rb` / `Configuration#periodic` | 2 apps gate periodic on `JOBS_ENABLED` (staging runs `RAILS_ENV=production`); 2 hand-roll `schedule.yml` loaders because `mgr.load_file` changes every lid (hiscore `b4fc16f`) | `WURK_PERIODIC=0` env (skip registration, log once). `load_file(path, lid: :name)` keeping caller-stable lids — check Ent's periodic spec for lid derivation first (`docs/target/sidekiq-ent.md`); lids are Redis-visible, so the default never changes. `authoritative!` default = human call U6. |
| K5 | `CHANGELOG.md` + new `wurk upgrade-check` | Every minor bump costs adopters a hand audit (hiscore `b4fc16f`, legald `841eb0d`, sales `548fd9dc`, tesote.com `7d5cfce`) | Per-release `### Upgrade notes` block with machine-greppable bullets (`removable-workaround:`, `behaviour-change:`); defer the command until 3 releases of notes exist. |

## Tests
- `test/unit/health_metrics_test.rb` per family (name, type, labels); `test/integration/swarm_restart_counters_test.rb` (kill -9 → `reason=crash` +1).
- `actionlint`-style validation of the example manifests if a tool is already in CI; else `ruby -ryaml` parse test.
- `bin/check`.

## Done when
- Every O-row metric appears in `docs/metrics.md` and in `/metrics` output of `bin/dev`.
- Examples referenced from `docs/deployment.md`; sizing table present.
