# Make Wurk better — adopter evidence + perf / memory / algorithm / structure sweeps

## Goal
Turn what five production adopters, one pending 7.x Pro/Ent migration (treasury), and seven read-only sweeps of the repo revealed into fixes: close the job-safety hole, delete the boilerplate every adopter re-invented, remove scaling cliffs, bound memory, and add the proof (soak, scale benches, budgets) that keeps it that way.

## Context
- **Overlap:** [`../101-evidence-driven-improvement-sweep/`](../101-evidence-driven-improvement-sweep/overview.md) was written the same day from the same sweeps by a parallel session and covers most of slices 01–09, 11, 12 here (plus one slice per adopter/infra repo). Execute **one** of the two, not both. Unique to this plan: [`10-code-structure.md`](10-code-structure.md) (incl. S1, `SCRIPT FLUSH` in four tests), 11 C3 (symbol anchors), 05 guards G1–G2. Owner picks; record it in `status.yml`.
- Baseline: v1.11.1 @ `f6f509e`, 2026-11-10. 0 open issues. ~265 Ruby files / ~36k lines in `lib/`. Ruby ≥ 3.2 (local 3.4.7; compat leg runs 3.2), Redis ≥ 7 with Lua, optional Rails engine, SolidJS + bun dashboard, Minitest on real Redis.
- Invariants (`CLAUDE.md`): Redis key schema / job JSON / score formats never change; `Sidekiq::*` aliases intact (`lib/wurk/compat.rb`); Sidekiq surface = `docs/target/sidekiq-{free,pro,ent}.md`; intentional divergences recorded in `docs/idea/parity-divergences.md`; no shims; no "faster" claim unless `docs/benchmarks.md` supports it; never DB 0 / `FLUSHALL` / `SCRIPT FLUSH`; no worktrees.
- Layer map: `lib/CLAUDE.md`. Test layers: `test/CLAUDE.md`. CI/release: `.github/CLAUDE.md`. Dashboard: `frontend/CLAUDE.md`.
- Sweeps (all read-only): adopters + logs + Sentry; treasury gap analysis; core runtime; dashboard/API/docs/CI; memory (with Redis-free measurements); algorithms (static); code structure (static). **Only R1 (poison race), S1 (`SCRIPT FLUSH` in tests) and the cited lines for A1, A3, A4, A5, M1, M2, R3, C1 were re-read by the plan author.** Everything else is a sweep finding: re-verify at the cited `file:line` before editing; anything a slice marks "inference" needs a reproducing test first.
- Adopters: `tesote/{sales,tesote.com,gringotts-wizarding-bank}`, `hiscore/hiscore.ro`, `developerz-ai/legaldiligencemedellin.com`. Local logs showed no wurk runtime fault; evidence is git history, config comments, Sentry. `tesote/treasury` = read-only. `tesote/sidekiq` = licensed Pro/Ent source — do not read or copy for implementation ([`07`](07-ecosystem-and-migration.md)).
- Reference patterns: Lua loading `lib/wurk/lua.rb` + `Wurk::Lua::Loader` (EVALSHA, NOSCRIPT recovery); boot checks `lib/wurk/boot_checks.rb`; CLI subcommands `lib/wurk/preflight/`; command counting `Wurk::Test::CommandSpy`; ecosystem harness `test/ecosystem/README.md`; prior plan style `docs/plans/2026/10/04/101-squeaky-clean-audit/`.
- Commands: `bin/check` (`fast`/`full`), `bin/rake test TEST=…`, `bin/rake test:parity`, `bin/rake test:ecosystem`, `bin/rake bench`, `bin/rake bench:vs_sidekiq`, `bin/repin-anchors`; in `frontend/`: `bun run test`, `bun run typecheck`, `bun run lint`.

## Headline (what hurts first)

| # | Finding | Slice |
|---|---|---|
| 1 | Reaper re-queues a reclaimed job before the poison decision → a live worker runs it while it is dead-set and its death handlers fire | 01 R1 |
| 2 | `unique_for:` without `unique!` silently never dedups (live in tesote.com); no boot warning | 01 R3, 12 |
| 3 | `main` red since 2026-11-07 (Python 3.9 leg) | 11 C1 |
| 4 | Four tests `SCRIPT FLUSH` the shared Redis (forbidden; likely flake source) | 10 S1 |
| 5 | Worker boot path differs from web/test → prod-only crash-loops in 4 apps; embedded swarm forks in the wrong process in all 5 | 02 B1–B3 |
| 6 | Unbounded Lua (`fast_delete_*` loads a whole queue); reaper full-keyspace `SCAN` per minute and per child boot | 03 A1, A2 |
| 7 | Idle workers block on the first queue only → up to 2s pickup latency on other queues | 03 A3 |
| 8 | Web process loads whole sets (`retry_all` jid set, scheduled `to_a`, 4,320-key pipeline); MAXMEM recycle can fork-loop | 05 M1–M4 |
| 9 | 7.x migrants: ms timestamps break app-side readers; Pro private-list shape unconfirmed; preflight catches ~⅓ | 07 E1, E2; 02 B10 |
| 10 | No soak/chaos ledger, no scale bench, no per-job command/allocation budget in CI | 09, 04 P3, 05 G1 |
| 11 | Still behind stock Sidekiq on noop + boot; cause unprofiled | 04 P1, P6 |

## Plan files (execute in order; see waves)
1. [`01-correctness.md`](01-correctness.md) — R1–R7: poison race, silent unique no-op, `Rails.error` reporting, hostname source.
2. [`02-boot-and-adoption-dx.md`](02-boot-and-adoption-dx.md) — B1–B17: `wurk boot-check`, embed role, hybrid detection, `exe/sidekiq`, sizing, periodic, preflight `--app` scans, proctitle, examples.
3. [`03-algorithms-scaling.md`](03-algorithms-scaling.md) — A1–A14: chunked Lua, targeted reaper, park rotation, cron O(K) + closed-form next-fire, limiter round trips, batched promotion/sweeps.
4. [`04-perf-hot-path-boot.md`](04-perf-hot-path-boot.md) — P1–P8: profile vs stock, weekly comparison run, command budget, lazy load, formatter.
5. [`05-memory.md`](05-memory.md) — M1–M12 + guards G1–G4: bulk-op memory, recycle guard, PSS option, warmup, budgets.
6. [`06-dashboard-api.md`](06-dashboard-api.md) — W1–W16: CSP, assets, paging cost, SSE cost, error truth, stock monitoring routes, OpenAPI.
7. [`07-ecosystem-and-migration.md`](07-ecosystem-and-migration.md) — E1–E9: timestamps, Pro list shape, plugin harnesses with real-worker checks, mixed fleet, 7.x guide.
8. [`08-observability.md`](08-observability.md) — O1–O9: restarts, RTT, pool timeouts, wedged workers, GC, alert rules.
9. [`09-proof-harness.md`](09-proof-harness.md) — T1–T7: soak/chaos jid ledger, key fuzz, scale benches, Redis restart.
10. [`10-code-structure.md`](10-code-structure.md) — S1–S12: test hygiene, `Keys` builders, TimerLoop, SignalPipe/ForkHooks, file splits, rejected list.
11. [`11-ci-docs-truth.md`](11-ci-docs-truth.md) — C1–C10: red main, symbol anchors, Rails matrix, doc contradictions.
12. [`12-human-decisions.md`](12-human-decisions.md) — H1–H11 + adopter follow-ups in their own repos.

## Waves (one PR in flight: build → PR → merged → pull → clean tree → next; ≤100 files per PR; ≤4 agents per wave, disjoint file sets, only the coordinator spawns)
- **Wave 0 (day 1):** C1 · S1 · notify tesote.com owner (12) · baseline: T3 scale numbers + G1/G2 budgets + P1 profile.
- **Wave 1 (job safety + truth):** R1+R2 · R3 · R7 · C3 (symbol anchors) · B4+B5+B6 · W7+W8 · E9/C6 doc sweep.
- **Wave 2 (adoption):** B2+B3 · B1 (non-breaking) + B8 + B13 + B15 · R5 oracle · E5 real-worker boot checks · O1–O5.
- **Wave 3 (scale + memory):** A1 → A2 → A4+A5 → A3 · M1+A8, M2, M3 · M4+G4 · S2+S6.
- **Wave 4 (proof):** T1 soak + nightly · T6 · E6 mixed fleet · E3/E4 harnesses · P6+P7 boot.
- **Wave 5 (surface + structure):** W1–W6, W9–W15 · S3–S5, S7–S11 · A6–A14 by T3 evidence · P4/P5/P8 by P1 evidence · B9–B12, B14, B16, B17 · O6–O8 · C4, C5, C9.
- **Gated:** B1 breaking (H1) · E2 (H7 dump) · E1c (H8) · W16 (H6) · C8 (H10).
- Release after waves 1, 2, 3 (`release: x.y.z` version-bump PR per `RELEASE.md`), then bump adopters (12).

## Done when
- R1's concurrent-consumer test and the 1h chaos soak show zero lost jobs and duplicates only inside the windows `docs/reliability.md` documents.
- A new Rails app on `gem "wurk"` needs none of the adopter workarounds (02 "Done when"); `wurk boot-check` + `wurk preflight --app` catch each recorded adopter incident shape in fixtures.
- No wurk Lua script or command is unbounded in a user-growable key except documented parity-inherent ones; idle pickup < 250ms on any queue with C ≥ Q.
- CI fails on: an added per-job Redis command, +3 objects/job, +10% boot features, `SCRIPT FLUSH` in tests.
- `docs/benchmarks.md` has: per-frame attribution of the noop gap, scale table (before/after), G4 CoW numbers, soak results — each with raw data.
- `main` green; `bin/check full` green; coverage ≥ 90/90; `bin/rake bench` no flagged regression.
- Every H-row has a dated decision in `status.yml`.

## Risks / open questions
- **Hot path:** R1, A2, A3, A7, A9 touch reclaim/fetch/enqueue/heartbeat — bench + parity on each; A3 must leave the 1-queue path at 1 trip / 3 commands.
- **Sweep accuracy:** costs in 03 are read, not measured; CoW impact in 05 is inference; flake causes in 10 are inference. T3/G4/reproduction come before the fix.
- **Anchor tax:** every `lib/` PR moves pinned line anchors until C3 lands — do C3 in wave 1.
- **Licensed source:** E2's key shape came from licensed Pro code on disk; nothing ships on it until H7's dump confirms.
- **Parity vs improvement:** several "better" behaviours (auto-unique, `WURK_COUNT` default, `authoritative!` default, idle timeout default, embed opt-in) diverge from Sidekiq or break users → human rows in 12, never silent.
- **Open:** `Thread.current[:wurk_capsule]` is fiber-local — does `Wurk.redis` inside a Fiber/Enumerator job use the wrong pool? Reproduce; if yes it joins 01. Statsd client shared across fork in embedded Puma workers? Verify (S5).
- **Root `CLAUDE.md` budget:** ~480 chars free; new commands documented in the nested CLAUDE.md files.
- **Adopter repos** are edited from their own checkouts; treasury never.
