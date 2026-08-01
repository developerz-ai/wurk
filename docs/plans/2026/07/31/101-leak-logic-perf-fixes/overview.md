# Leak, logic-bug & perf audit fixes

## Goal

Fix the confirmed resource-lifecycle leaks (fork/at_exit/teardown), correctness bugs (job loss, duplicate execution, wrong stats), Redis key-hygiene leaks, and low-risk perf wins surfaced by the five-agent deep audit of 2026-07-31 (process lifecycle · execution/web · frontend/tests · logic/concurrency · perf).

## Context

- Repo: `wurk` — Ruby gem, Sidekiq drop-in (free+Pro+Ent). Pillars in `CLAUDE.md`: wire-compat sacred (never change Redis keys / job JSON / scores), no tiers, benchmarked (>5% regression on enqueue / fetch+execute / bulk enqueue / swarm boot / memory blocks merge).
- Ruby >= 3.2, redis-client + connection_pool. Tests: `bin/rake test` (parallel, per-worker Redis DB), `bin/rake test:parity`, `bin/rake bench`. Coverage gate ≥90% line+branch on `lib/`.
- Frontend: SolidJS SPA under `frontend/`, `bun run test` (vitest).
- Authoritative Sidekiq spec: `docs/target/sidekiq-{free,pro,ent}.md`. Intentional divergences recorded in `docs/idea/`.
- **Prior plan** `docs/plans/2026/07/17/101-redis-resilience-audit-fixes/`: its slice 01 (pool split, retry wrapper, `POOL_HEADROOM`, dedicated fetch pool) is visibly landed in code even though its `status.yml` still says `not_started` — refresh that tracker before executing; do not redo landed work. This plan's 04 (retry idempotency) *amends* that landed retry wrapper.

### Finding ID conventions (used across slices)

| Prefix | Audit dimension |
|---|---|
| A1–A13 | fork/process lifecycle (swarm, launcher, railtie) |
| S1–S14 | execution + web layer (client buffer, batch, SSE) |
| F1–F16 | logic/concurrency bugs |
| P1–P13 | perf opportunities |
| T#/FE# | test-harness / frontend |

## Plan files (execute in order)

1. [`01-swarm-launcher-teardown.md`](01-swarm-launcher-teardown.md) — **critical**: child-inherited `at_exit` SIGKILL cascade; `Launcher#stop` ensure; embedded-boot leaks; fork hygiene.
2. [`02-fetch-pause-reaper.md`](02-fetch-pause-reaper.md) — all-queues-paused hot-spin; reaper PID-namespace liveness (job loss / dup execution); interrupt re-push wrong end.
3. [`03-client-buffer-fork-safety.md`](03-client-buffer-fork-safety.md) — outage buffer fork-unsafety (dup jobs, dead drainer, mutex deadlock); overflow `:raise` job drop.
4. [`04-redis-retry-idempotency.md`](04-redis-retry-idempotency.md) — `RedisPool#with` blind replay of non-idempotent blocks (dup enqueue, lost scheduled jobs, dropped signals).
5. [`05-leader-cron-limiter-logic.md`](05-leader-cron-limiter-logic.md) — non-atomic leader release; cron double-fire; limiter clock-skew / spin / dead metrics.
6. [`06-batch-limiter-key-hygiene.md`](06-batch-limiter-key-hygiene.md) — unbounded `batches` / `dead-batches` ZSETs, TTL-less batch sub-keys, `lmtr-list` growth, callback append cap.
7. [`07-stats-web-misc.md`](07-stats-web-misc.md) — poison-pill counter never cleared (silent job kill); wrong-stats fixes; web memo/guard fixes.
8. [`08-perf-quick-wins.md`](08-perf-quick-wins.md) — behavior-preserving perf: allocation memos, statsd guard, SSE payload de-dup, pre-fork Lua load. Risky items explicitly deferred.
9. [`09-frontend-fixes.md`](09-frontend-fixes.md) — AbortController on extension fetches, toast timers, modal retention, SSE test reset.
10. [`10-test-bench-hygiene.md`](10-test-bench-hygiene.md) — leaked launchers/processors/swarms in tests; AR handle across parallel fork; benchmarks trashing Redis DB 0.

Reference (not a work slice): [`notes-non-findings.md`](notes-non-findings.md) — verified-safe spots each audit cleared. **Read before "fixing" anything not listed in a slice** — these look like bugs and are not.

Slices are independent except: 08 touches files owned by 02 (fetcher) and 07 (metrics) — run 08 after both, or rebase carefully. If parallel subagents are used: same-checkout, disjoint slices only (repo rule: no worktrees).

## Done when

- `bin/rake test` + `bin/rake test:parity` green; coverage ≥90% line+branch holds.
- Benchmark bot shows no >5% regression on any of the five benches (08 should show improvements on enqueue/fetch+execute/swarm boot).
- Every fix has a regression test proving the leak/bug (leaked FD/thread count, duplicate-execution scenario, key-TTL assertion) — not just the happy path.
- No Redis key, job JSON field, or score format changed anywhere (02's private-list key extension is the one deliberate exception — see its wire-compat note).
- `bun run test` green for 09.
- Intentional behavior changes vs Sidekiq (F14 UTC date, F1 sleep) recorded in `docs/idea/`.

## Risks / open questions

- **02 / F2 private-list key incarnation nonce** changes the private-list naming scheme (`queue:<q>|<host>|<pid>|<idx>` → adds nonce). Old-format keys must remain reclaimable (reaper reads both) or existing in-flight jobs strand on upgrade. This is the highest-touch wire decision in the plan — implement with a migration-window reader.
- **04 retry policy** narrows when duplicate side-effects can occur; at-least-once still holds. Do not widen retries — callers opt in.
- **F4 cron CAS Lua** adds a script — keep `loops:<lid>` hash fields identical (wire compat with dashboards).
- **08**: apply only the "risk: none/low" items; the deferred list (Lua-folded fetch P1a, history aggregation P2b, single `verify_json` P6, scheduler batching P12) needs explicit maintainer sign-off each.
- Prior-plan overlap: slices 02/03 of the 07/17 plan (shutdown requeue, supervision) partially intersect 01 here — check per-finding whether code already changed before patching.
