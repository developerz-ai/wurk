# Squeaky-clean audit → production-grade Wurk

## Goal
A big customer is about to run Wurk in production, likely migrating live from Sidekiq Pro/Ent. Fix every verified bug, close every open issue, and close the production-readiness gaps so a high-volume deployment and a Sidekiq→Wurk cutover are proven safe, not just claimed.

## Context
- Ruby gem, drop-in Sidekiq + Pro + Ent (`CLAUDE.md` = invariants: wire-compat, boot ordering, per-fork Redis pool, reliable fetch, signals). Spec = `docs/target/sidekiq-{free,pro,ent}.md` (**currently deleted in working tree — restore first, [`01`](01-repo-hygiene.md)**).
- Audit 2026-10-04, v1.7.6 @ `8126e42`, 9 read-only passes: core runtime, Pro/Ent/API, web/dashboard, CI/release/tests, `../infrastructure`, top-down trace, bottom-up trace, production readiness, open issues. ★ in slices = found independently by ≥2 passes.
- Baseline that is healthy: main CI green since 2026-09-07; coverage 97.67% line / 92.58% branch; frontend lint + 282 vitest green; reliable fetch + reaper + kill -9 tests; bounded key growth; no TODO/FIXME in `lib/`.
- Commands: `bin/check` (`fast`/`full`), `bin/rake test TEST=…`, `bin/rake test:parity`, `bin/rake test:ecosystem`, `bin/rake bench`, `cd frontend && bun run test && bun run lint`.
- Rules for every PR: tests written with the code; never mock Redis in integration/parity; never change key schema/JSON unless *restoring* Sidekiq's format (E8); bench ≤5% regression; Sidekiq aliases intact; intentional divergences go in `docs/idea/parity-divergences.md`.
- Team execution: CLAUDE.md says no worktrees — parallel agents split by **disjoint files** (splits given in [`02`](02-core-runtime.md) Steps and [`03`](03-pro-ent-api.md) Steps).
- Audit side-note: the Pro/Ent pass flushed Redis DB 13 during repros — rerun any suite that was running then.

## Headline (what would hurt the customer first)
| # | Finding | Slice |
|---|---|---|
| 1 | Job exceptions never reach `error_handlers` → Honeybadger/Rollbar/Bugsnag/etc. silent | 02 K2 |
| 2 | Scheduler thread dies permanently on a Redis blip → retries/scheduled stop | 02 K1 |
| 3 | Plaintext secrets re-pushed on interrupt of encrypted jobs | 03 E5 |
| 4 | `mount Sidekiq::Web` bypasses authorization; SSE tabs starve Puma threads | 04 W1, W2 |
| 5 | Reaper can double-run a live worker's job; batch callbacks fire early / get lost | 02 K5; 03 E3, E25–E27 |
| 6 | `sidekiq_retry_in { 10.minutes }` and AJ `retry:` ignored | 02 K3, K4 |
| 7 | Pro/Ent wire formats + mixed fleet + rollback never tested against real Pro/Ent | 09 R2–R4 |
| 8 | Migration guide overclaims ecosystem gem compat; shim gem undocumented | 09 R5 |
| 9 | Spec deletion / docs-only / rubocop-only PRs merge without running their checks | 05 C1–C4 |

## Plan files (execute in order; 05 can start in parallel with 01)
1. [`01-repo-hygiene.md`](01-repo-hygiene.md) — restore spec files; doc-truth items; forbidden-claim test.
2. [`02-core-runtime.md`](02-core-runtime.md) — K1–K29: processor/retry/scheduler/swarm/reaper/redis pool.
3. [`03-pro-ent-api.md`](03-pro-ent-api.md) — E1–E31: batches, cron, limiters, encryption, metrics, API iteration, aliases/shims.
4. [`04-web-dashboard.md`](04-web-dashboard.md) — W1–W17: auth bypass, SSE, health server, SPA error/paging bugs, Sidekiq::Web API.
5. [`05-ci-gates.md`](05-ci-gates.md) — C1–C12: path filters, skip-as-pass, dependabot→bun, release main guard. Closes #469 #541 #470.
6. [`06-release-lane.md`](06-release-lane.md) — rake release lockout, demo lock + version guard. Closes #491 #482.
7. [`07-lint.md`](07-lint.md) — rubocop pin, PredicateMethod config, `rescue Exception` review. Closes #471 #477.
8. [`08-test-hygiene.md`](08-test-hygiene.md) — flakes, sleep barriers, `track_files`, parity oracle expansion. Closes #522 #486.
9. [`09-production-readiness.md`](09-production-readiness.md) — R1–R20: migration proof, Redis topologies, many-queue fetch, cgroup forks, soak/chaos, metrics exporter, runbook.
10. [`10-infrastructure.md`](10-infrastructure.md) — demo producer fork bug + doc drift (here); runner watchdog, image pinning, secrets (infra repo).
11. [`11-human-actions.md`](11-human-actions.md) — U1–U13: ruleset, release env, decisions, Pro/Ent dump from customer, support/SLA.
12. [`12-issue-closure-map.md`](12-issue-closure-map.md) — every open issue/PR → slice/batch; #488, #537 details; new issues to file.

## Suggested sequencing (waves)
- **Wave 0 (day 1):** 01 H1; 05 C1–C4, C7; file new issues per 12.
- **Wave 1 (P0, week 1):** 02 K1, K2, K6, K10; 03 E5, E10, E12; 04 W1, W2, W7; 09 R5 doc truth, R9, R12.
- **Wave 2 (P1):** rest of 02 P1; 03 batch + cron clusters; 04 W3–W6; 06; 07; 08 #522/#486.
- **Wave 3 (proof):** 09 R2–R4 (needs U8), R7, R8, R11 soak, R14; 08 parity expansion.
- **Wave 4:** P2/P3 everywhere; 10 infra; 12 #488, #537 (after U6).

## Done when
- All P0/P1 rows across 02/03/04/09 fixed with tests, or recorded as intentional in `docs/idea/parity-divergences.md` with reason.
- Open-issue list = only human-gated items with recorded decisions (12).
- `bin/check full` green; coverage ≥90/90 with `track_files`; parity suite ≥10 oracle files; `rake bench` no >5% regression.
- 24h soak w/ chaos (kill -9 children, Redis restart): zero lost/duplicated jids, flat RSS + key count; numbers in `docs/benchmarks.md`.
- `docs/migrate-from-sidekiq.md` has a tested production cutover + rollback procedure; `docs/runbook.md` exists.
- Real Pro/Ent dump replay passes (U8 → R2).

## Risks / open questions
- **Wire-compat vs fixes:** E8 (metrics key year) and E13 (batch marker names) change what Wurk writes — they *restore* Sidekiq format; note in CHANGELOG; Wurk-written old keys expire naturally.
- **Hot paths:** K5, K11, K24, R8, R12 (reliable scheduler default) touch fetch/enqueue — bench every PR.
- **E13/R2/R3 are `plausible` until a real Pro/Ent dump exists** — don't redesign batch storage on guesswork; get U8 first.
- **K24 `reconnect_attempts: 0`** may surface more errors to callers — measure blip-test behaviour before switching.
- **K27 / K7** change Rails boot behaviour — call out in CHANGELOG as behaviour change.
- **C6 path choice** (delete lockfile workflow vs dispatch) depends on whether dependabot-bun updates `bun.lock` itself — verify with one real run.
- **#537** is frozen by #530's protocol — touching it before U6 spoils a registered experiment.
- `docs/target` deletion culprit unknown and recurring (cf4b25f precedent) — U13.
