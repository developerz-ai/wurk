# 12 — Proof harness (soak · chaos · mixed fleet · budgets)

> Part of [`overview.md`](overview.md). Depends on: [`02`](02-reclaim-correctness.md) (don't soak a known race). 3 PRs (T1 · T2 · T3–T5). Carries over old-audit R4/R11.

Defect history since 2026-09-01 (56 fix commits): most runtime churn = (1) compat only visible when a real worker boots with a real gem / non-default runtime, (2) reaper key parsing + reclaim races (#751, #755, #758, #879, #558). #879's chaos runs were never committed.

## Files to change
| ID | Where | Gap | Change |
|---|---|---|---|
| T1 | new `bench/soak/` (`run.rb`, `ledger.rb`, `chaos.rb`), `Rakefile` task `bench:soak`, new `.github/workflows/soak.yml` (schedule + `workflow_dispatch`, never on PRs) | No committed soak/chaos; no long-uptime RSS or key-count proof | Mixed workload (plain, batch w/ nested callbacks, unique, limiter, cron, iterable, scheduled) on a private-port Redis. Chaos: random `kill -9` child, Redis restart from RDB, `CLIENT PAUSE`, optional Sentinel failover (reuse `topology.yml` setup). Jid ledger: every pushed jid ran ≥1×; duplicates counted + attributed to a named at-least-once window. Sample per-child RSS/PSS, `DBSIZE`, key count by prefix every 5 min. Output JSON artifact + summary table; nightly = 1h, manual = 24h. |
| T2 | new `test/integration/mixed_fleet_test.rb`, own CI job | Sidekiq + Wurk on one Redis during a rolling cutover never tested (guide says unsupported; old R4) | Real Sidekiq 8.1 from `bench/vs_sidekiq/Gemfile` + `wurkswarm`, one DB. Assert via ledger: no loss/dup; scheduled promotion by either side; fate of Wurk private lists after Wurk stops; Sidekiq reading Wurk-written payloads (ms timestamps). Outcome decides whether the guide can offer rolling cutover or keeps drain-only. |
| T3 | `.github/workflows/bench.yml`; `Rakefile:156` (`UNGATED_SCRIPTS` holds `command_count.rb`) | Commands-per-job budget unchecked in CI | Run `bench/command_count.rb` (deterministic) as a step; fail on increase vs the number recorded in `docs/benchmarks.md`. |
| T4 | `.github/workflows/bench.yml` | `bench:vs_sidekiq` never scheduled | Nightly on one runner, artifact only; never gates. |
| T5 | ruleset (human, U1) | Ruby 3.2-floor compat leg not required; `main` regressed twice (#823, #878) | Decide: require the 3.2 leg on `lib/**` changes, or name an owner for the scheduled red. |
| T6 | `bin/check` (`fast`) | `lib/` edits move ledger anchors; 22/65 `lib/` commits since 2026-09-01 also touched ledger files; `fast` doesn't check | `bin/check fast` runs `bin/repin-anchors --check`. Longer term: finish symbol/quoted-fragment anchors (#865 direction), drop `#Lx-Ly`. |

## Steps
1. T1 ledger is the reusable piece: T2 and [`02`](02-reclaim-correctness.md) tests import it. Lives under `bench/soak/`, not `lib/`.
2. Soak never touches DB 0, never `FLUSHALL`/`SCRIPT FLUSH`; private port.
3. Publish first soak numbers in `docs/benchmarks.md` (new "Soak" section: hours, jobs, kills, lost=0, dup count by window, RSS slope, key-count slope).

## Tests
- `bin/rake bench:soak DURATION=120` locally (2 min smoke) → exit 0, ledger balanced.
- `bin/rake test TEST=test/integration/mixed_fleet_test.rb`.

## Done when
- 24h manual soak: 0 lost jids, every dup attributed, RSS/PSS and key-count slopes flat within stated tolerance; numbers in `docs/benchmarks.md`.
- Mixed-fleet result recorded in `docs/migrate-from-sidekiq.md` (supported or not, with the test as evidence).
- `command_count` step red when a per-job command is added.
