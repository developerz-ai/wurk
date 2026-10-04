# 09 — Production readiness (big-customer bar)

> Part of [`overview.md`](overview.md). Depends on: [`02`](02-core-runtime.md), [`03`](03-pro-ent-api.md) P0/P1 fixed. Source: production-readiness audit 2026-10-04 (v1.7.6, `8126e42`).

**Verdict as of audit:** core reliability is solid (BLMOVE fetch, reaper w/ kill -9 integration tests, Redis blip self-heal, k8s shutdown guidance, bounded key growth). Not yet ready for a **live in-place Pro/Ent migration at high volume**. The gaps are mostly in *proof* (no real Pro/Ent data, no mixed fleet, no soak test), plus one silent error-reporting gap.

## Gaps

| ID | Sev | Area | Gap | Evidence | Fix | Size |
|---|---|---|---|---|---|---|
| R1 | P0 | Error reporting | Job exceptions never reach `config.error_handlers` (Sidekiq Processor calls `handle_exception(e, context: "Job raised exception")`); Wurk swallows `JobRetry::Handled`. Honeybadger/Bugsnag/Rollbar/Airbrake/Datadog/custom hooks go **silent**. Not in `parity-divergences.md`. | `lib/wurk/processor.rb:249-253`; `docs/migrate-from-sidekiq.md:512-521` | **Owned by [`02`](02-core-runtime.md) K2** (found by 4 passes). | S |
| R2 | P0 | Migration | Pro/Ent Redis formats never validated vs real Pro/Ent (private lists, batch hashes, `lmtr*`, `unique:<sha256>`, `dear-leader`, `loops:`). Spec marks keys "observed". | `docs/compatibility.md:27-36`; ent spec :164; `test/fixtures/` only `demo_ext` | Get a real Pro+Ent Redis dump (customer has licenses) w/ in-flight batches, limiters, uniques, periodic, SIGKILLed super_fetch. Build `test/fixtures/pro_ent_dump/` (scrubbed) + replay integration test. HITL to obtain dump ([`11`](11-human-actions.md)). | M |
| R3 | P0 | Migration | Pro `super_fetch` orphan recovery only if private lists match `queue:<q>\|host\|pid\|idx`; other shapes silently skipped forever. | `lib/wurk/fetcher/reaper.rb:224,232-262` | Validate with R2 dump; log WARN once per unparseable `queue:*\|*` key. | S |
| R4 | P0 | Mixed fleet / rollback | "Share Redis safely / roll back anytime" claimed, untested. Wurk 5-segment private lists (`…\|nonce\|idx`) never reclaimed by OSS Sidekiq; Ent leader + unique interop unverified → double cron / dup uniques during overlap. | `docs/migrate-from-sidekiq.md:69-71,317-318,529-532`; `lib/wurk/fetcher/reliable.rb:77-80` | Integration job running real sidekiq 8.1 OSS beside Wurk on one Redis (reuse `bench/vs_sidekiq` bundle). Until proven: doc says **drain cutover only** (quiet Sidekiq → busy + private lists empty → start Wurk); rollback step drains `queue:*\|*` first. | M |
| R5 | P0 | Ecosystem docs | Migration guide says sidekiq-scheduler/-status/-failures/-throttled "✅ work unchanged, suites in CI"; only sidekiq-cron is in matrix. Shim gem requirement undocumented (only `docs/sentry.md:31-37`). | `docs/migrate-from-sidekiq.md:366-369,452-461` vs `test/ecosystem/README.md:28-29`, `docs/idea/14-ecosystem-compat.md` | Fix table to truth now; document `sidekiq` shim gem prominently. Then add harnesses: unique-jobs (needs E10), scheduler, failures, throttled, status. | S doc / M per harness |
| R6 | P1 | Migration from add-ons | Moving from sidekiq-unique-jobs / sidekiq-cron to native: existing `uniquejobs:*` locks + cron schedules not honoured/imported. | `docs/migrate-from-sidekiq.md:372-420` | Doc overlap procedure; optional `rake wurk:import:cron` / `:unique`. | S |
| R7 | P1 | Redis topology | Sentinel/TLS/ACL pass-through only unit-tested; CI = Redis 7.4 standalone. Valkey/Dragonfly/ElastiCache/MemoryDB undocumented; dynamic-key Lua breaks Dragonfly. | `lib/wurk/redis_options.rb:48-55`; workflows `redis:7.4` | Integration: Sentinel failover mid-BLMOVE, TLS (`rediss://` self-signed), ACL user. CI matrix-free: one extra job w/ Valkey 8 (cheap). Supported-backends matrix in `docs/deployment.md`. Lua key fix = E23. | M |
| R8 | P1 | Scale: many queues | Fetch = sequential non-blocking LMOVE per queue then BLMOVE(2s) on `queues.first` only → 100 queues = 100 RTT/fetch when sparse; idle polling ≈ queues×threads×forks/2s; strict-mode latency up to 2s for later queues. Sidekiq BRPOP = 1 call. | `lib/wurk/fetcher/reliable.rb:255-263`; `docs/reliability.md:131-146` | Lua multi-queue claim (one RTT: iterate KEYS, LMOVE first non-empty) — keeps BLMOVE reliability; bench with 100 queues in `rake bench` (new block). Respect weighted shuffle. | M |
| R9 | P1 | Scale: fork count | Default `WURK_COUNT = Etc.nprocessors` ignores cgroup `cpu.max` → 64 forks in a 2-CPU pod. | `lib/wurk/configuration.rb:820-826`; `docs/deployment.md:512-516` | Read cgroup v2 `cpu.max` / v1 `cfs_quota_us`; `ceil(quota/period)`; floor 1. Log chosen count at boot. | S |
| R10 | P2 | Scale: DB pool | No boot check AR pool ≥ concurrency (Redis pool checked only). | `lib/wurk/cli.rb:357-359` | WARN at child boot if `ActiveRecord::Base.connection_pool.size < concurrency`. | S |
| R11 | P1 | Load evidence | Bench = 5k jobs, 1/4 procs. No 32+ forks, 50+ threads, 10k+ push_bulk, 100+ queues, big payloads, multi-million, no 24h soak. README "millions/hour" claim unbacked. | `docs/benchmarks.md:15`, `bench/` | `bench/soak/` harness: 24h run, sample RSS per child + Redis `INFO memory` + key count by pattern every 5m; chaos: random `kill -9` child + Redis restart every N min, assert zero lost jids (ledger). Publish numbers in `docs/benchmarks.md`. Remove/qualify README claim until backed. | M |
| R12 | P1 | Durability defaults | Default scheduler has job-loss window (`reliable_scheduler!` opt-in); client outage buffer `:drop_oldest` silently drops. | `docs/reliability.md:19-41`; `lib/wurk/client/buffered.rb:17-22` | Cutover checklist requires `reliable_scheduler!`; evaluate making it default (measure cost in `rake bench`). Drop → log ERROR + metric counter per drop. | S |
| R13 | P1 | Parity coverage | 3 oracle files. | `test/parity/*.rb` | See [`08`](08-test-hygiene.md) parity expansion. | L |
| R14 | P2 | Observability | No Prometheus/OTel *metrics* exporter (OTel = traces only); JSON logs opt-in; health = only port-owning child; parent never checks running child heartbeat. | `docs/metrics.md:444-446`; `docs/deployment.md:390-394`; `lib/wurk/swarm.rb:597` | `/metrics` (Prometheus text) on health server: queue size/latency, busy, processed/failed, retry/dead size, per-child RSS. Parent supervision: child heartbeat stale > N×interval → SIGTERM → SIGKILL → respawn (log). Health aggregates children via heartbeat keys. | M |
| R15 | P2 | Runbook | No incident runbook. | `docs/reliability.md:604-636` | `docs/runbook.md`: stuck queue, orphaned private lists, latency spike, leader stuck, poison-job storm, Redis failover, memory growth, rollback to Sidekiq. Each: symptom → dashboard/CLI check → command. | S |
| R16 | P2 | Reaper cost | Hourly full-keyspace `SCAN queue:*\|*` COUNT 100. | `lib/wurk/fetcher/reaper.rb:64,190-200` | Registry SET of private lists (SADD on create, SREM on clean); keep SCAN as rare fallback (daily) for Pro-made lists. **Wire-compat:** new key is Wurk-only — namespace it, document in `docs/compatibility.md`. | M |
| R17 | P2 | Dashboard | SSE thread starvation; `Sidekiq::Web.call` auth bypass. | — | Code fixes in [`04`](04-web-dashboard.md) W1/W2; doc "mount dashboard on separate web role" for big deployments. | S |
| R18 | P3 | Security | Args not redacted in logs/dashboard unless encrypted. | `lib/wurk/job_logger.rb` | Optional `config.redact_args = ->(job){…}` applied in logger + dashboard JSON; doc. | S |
| R19 | P3 | Long uptime | Mostly fine (TTL'd/trimmed keys; bounded caches). Per-class metric keys grow with distinct class names. | `docs/metrics.md:420-440` | Confirm via R11 soak. | — |
| R20 | P2 | Versioning/support | 4.5 months old, 31 releases; roadmap M6 1.0 exit criteria unmet; migration guide "pending v1.0.0 sign-off"; support = GH issues; SECURITY.md 3-day ack. | `CHANGELOG.md:425`; `docs/idea/13-roadmap.md`; `SECURITY.md` | HITL: support channel + LTS line for the customer; reconcile 1.0 claims in docs. | S |

## Steps (order)
1. R1 (biggest day-1 risk), R5 doc truth, R12 drop logging, R9 cgroup — one week of small PRs.
2. R4 drain-cutover doc + R15 runbook — the customer's migration playbook (`docs/migrate-from-sidekiq.md` "Production cutover" section: pre-flight checklist, drain, verify, rollback).
3. R2/R3 once dump arrives; R6.
4. R8 fetch, R16 reaper, R14 metrics + child liveness.
5. R7 topology tests, R11 soak/chaos, publish numbers.
6. R10, R18, R20.

## Tests
- R1: parity oracle — failing job → each `error_handlers` entry called once with `context: "Job raised exception"` + job hash.
- R4: `test/integration/mixed_fleet_test.rb` (real sidekiq process) — gated to its own CI job if bundle conflicts.
- R8: bench block `fetch_100_queues`; integration: job on queue #100 picked within one fetch cycle.
- R9: unit w/ fake cgroup files (tmpdir).
- R11: soak harness runs on self-hosted box; results committed to `docs/benchmarks.md`.
- R14: parent kills child with stale heartbeat (integration, real fork).

## Done when
- No P0 open; P1 open only with dated customer-agreed exceptions.
- `docs/migrate-from-sidekiq.md` has a tested production cutover + rollback procedure.
- Soak: 24h, zero lost jids under chaos, flat RSS, flat key count — numbers published.
