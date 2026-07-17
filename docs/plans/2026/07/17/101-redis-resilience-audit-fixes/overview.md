# Redis resilience + full-codebase audit fixes

## Goal

Fix the production Redis failure modes (`RedisClient::ReadTimeoutError` ×803, `RedisClient::CannotConnectError` ×100, `ConnectionPool::TimeoutError "0/7 available"`) so transient Redis trouble self-heals with retry+backoff instead of failing jobs — no process restart needed. Plus fix the confirmed correctness bugs, supervision gaps, web/frontend defects, and spec divergences surfaced by a six-agent deep audit (2026-07-17).

## Context

- Repo: `wurk` — Ruby gem, Sidekiq drop-in (free+Pro+Ent). Pillars in `CLAUDE.md`: wire-compat sacred, no tiers, benchmarked. Never change Redis key schema / job JSON.
- Ruby >= 3.2, redis-client + connection_pool, minitest parallel (`bin/rake test`), parity suite `bin/rake test:parity`, coverage gate ≥90% line+branch on `lib/`.
- Frontend: SolidJS SPA under `frontend/`, `bun run test` (vitest), built to `vendor/assets/`.
- Authoritative Sidekiq spec: `docs/target/sidekiq-{free,pro,ent}.md`. Intentional divergences must be recorded in `docs/idea/`.

### Root causes of the production incident (confirmed)

| Symptom | Root cause |
|---|---|
| `ReadTimeoutError` ×803 | `RedisPool` passes flat `timeout: 1.0` → read/write/connect all 1.0s (`lib/wurk/redis_pool.rb:16,64`); no retry — `RETRYABLE_MSG` only matches `READONLY\|NOREPLICAS\|UNBLOCKED` (`redis_pool.rb:22,34-48`); error surfaces inside jobs via `JobRetry` as a job failure |
| `CannotConnectError` ×100 | `reconnect_attempts` never set (=0); no post-fork PING validation (`swarm/child_boot.rb:73-74`) |
| `TimeoutError 0/7` | Pool = `concurrency + 2` = 7 (`capsule.rb:95-99`) vs 13–15 consumer threads (`launcher.rb:81-99`); 5 processors park in shared-pool BLMOVE ~2–3s each when idle (`fetcher/reliable.rb:130-139`); checkout timeout = same 1.0 constant; web dashboard rides the same pool (`lib/wurk.rb:129-137`) |

## Plan files (execute in order)

1. [`01-redis-resilience.md`](01-redis-resilience.md) — pool config split, retry+backoff wrapper, pool sizing, dedicated fetch pool, post-fork validation, buffer gap. **The production fix — do first.**
2. [`02-shutdown-requeue-safety.md`](02-shutdown-requeue-safety.md) — hard-shutdown double-execution fix, quiet/fetcher semantics, CONT resume.
3. [`03-swarm-supervision.md`](03-swarm-supervision.md) — railtie-under-Puma guard, crash-loop backoff, non-blocking rolling restart, orphan watchdog, signal safety, Manager locking.
4. [`04-batch-scheduler-logic.md`](04-batch-scheduler-logic.md) — BATCH_PUSH re-registration root cause (3 bugs), limiter/batch middleware order, ReliableEnq `enqueued_at`, dead-set trim.
5. [`05-web-api-hardening.md`](05-web-api-hardening.md) — CSRF guard, web-layer pool, SSE caps, search scan bounds, Redis-error observability.
6. [`06-frontend-fixes.md`](06-frontend-fixes.md) — mutation error toasts, Search page rewrite, mount-path portability, i18n completeness, missing features, tests.
7. [`07-parity-spec-alignment.md`](07-parity-spec-alignment.md) — spec reconciliation + small parity fixes + `docs/idea/` divergence records.

Slices 02/03/04 are independent of 01. 06 depends on 05 (base-path injection). 07 is independent.

## Done when

- All three production error classes handled: transient Redis errors retried with backoff+jitter (then raised); pool never sized below its consumer count; blocking fetch isolated from the shared pool; `bin/rake test` + `test:parity` green.
- Timed-out shutdown produces exactly-once-or-at-least-once *without systematic 2×* (test proves single delivery in the normal timeout path).
- Batch with a retried job still fires `:success`; `pending`/`total` not inflated.
- No CSRF on mutating API without same-origin guard; dashboard works mounted at any path.
- Coverage ≥90% line+branch maintained; benchmark bot shows no >5% regression.
- Intentional divergences recorded in `docs/idea/`; the two target-spec conflicts reconciled.

## Risks / open questions

- **Retry-safety of non-idempotent commands**: after a `ReadTimeoutError` the command may have executed server-side. Auto-retrying `LPUSH`/`INCR` risks duplicates. Wurk is at-least-once by design → acceptable default, but the wrapper must be explicit (see 01 §retry classes). Reads/EVALSHA-idempotent ops always safe to retry.
- **Config surface**: new pool/timeout options must stay Sidekiq-compatible (`config.redis = {...}` pass-through, not novel top-level options). 01 defines the mapping.
- **Limiter dead-set vs re-raise divergence** (Ent §1.4): keep Wurk behavior + document, or match spec? Plan: keep + record in `docs/idea/` (07); flip only if maintainer overrules.
- **`BasicFetch` alias**: reliable-by-default is a pillar; do NOT implement BRPOP mode. Record as intentional divergence (07).
- Changing default read timeout (1.0→2.5s) changes worst-case fetch-loop stall characteristics — benchmark before merge.
