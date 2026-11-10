# 01 — Correctness: job safety + silent no-ops

> Part of [`overview.md`](overview.md). Depends on: none. Ship first. One PR per row group (R1+R2, R3, R4, R5+R6, R7).

Source: core-runtime sweep + adopter sweep, 2026-11-10 @ `f6f509e` (v1.11.1). R1 re-read and confirmed by the plan author; the rest are sweep findings — re-verify each at the cited lines before editing.

## Files to change

| ID | Sev | Where | Defect → scenario | Fix |
|---|---|---|---|---|
| R1 | P0 | `lib/wurk/lua.rb:163-170` (`RELIABLE_RECLAIM`), `lib/wurk/fetcher/reaper.rb:327-370` (`drain`, `poison_off`), `lib/wurk/middleware/poison_pill.rb:63-83,185-211` | Reclaim `RPUSH`es to the public tail (the end `LMOVE … RIGHT` pops) *before* the poison decision. A `BLMOVE`-parked worker takes job J; reaper then INCRs, `DeadSet#kill`s J (death handlers: batch `:death`, unique release) while J runs; `LREM public -1` finds nothing. J in dead set + a private list; poison job crashes another worker. Same path via `Reaper#recovered` (SelfReconcile). | Decide before visibility: `LINDEX private -1` → bump counter → over threshold: one Lua `ZADD dead` + guarded `RPOP private` (ARGV = peeked payload; no-op if tail changed); else `RELIABLE_RECLAIM` with the same tail guard. Same keys, same dead-set member/score format (`DeadSet#kill` is the reference for score + trim). Death handlers fire after the Lua returns. |
| R2 | P2 | `lib/wurk/middleware/poison_pill.rb:185-191` `bump_counter` | `INCR` then `EXPIRE` = 2 round trips; failure between leaves `super_fetch:recovered:<jid>` without TTL. | One pipelined `MULTI` (or fold into R1's script). Same key, same TTL. |
| R3 | P1 | `lib/wurk/boot_checks.rb:64-83` (`warn_on_ignored_locks` — checks `lock:` only, `Wurk::Worker` subclasses only) | `sidekiq_options unique_for:` without `unique!` enqueues duplicates, no warning (`docs/unique-jobs.md:29`). Live in an adopter: `BroadcastDeliverJob` (tesote.com) has never deduped. ActiveJob classes never inspected. | New check beside it: any loaded class (Worker subclasses + ActiveJob classes carrying `sidekiq_options`) with `unique_for`/`unique_until` while `Unique` middleware is not installed → WARN listing classes + the one-line fix (`Sidekiq::Enterprise.unique!`). Do **not** auto-enable (Ent requires the explicit call — parity). |
| R4 | P1 | `lib/wurk/unique.rb` client middleware; `lib/wurk/testing.rb` | Adopter skips `unique!` in tests because the client middleware needs Redis under `Sidekiq::Testing.fake!`. | First check upstream Ent behaviour in `docs/target/sidekiq-ent.md` (unique + testing). If Ent no-ops under fake/inline → match it; if spec is silent → record entry in `docs/idea/parity-divergences.md`, then no-op. |
| R5 | P1 | `lib/wurk/rails_reloader.rb:13` (`Rails.error` wrap, `source: 'job.sidekiq'`), `lib/wurk/processor.rb:448` (`build_instance`), `lib/wurk/sentry/error_handler.rb` | `Rails.error` subscribers (sentry-rails `register_error_subscriber`) get one event per attempt, incl. `NameError` from `build_instance` and control-flow `JobRetry::Skip`/`Handled` — bypasses terminal-only rule of `Wurk::Sentry`. | (a) Oracle first: what stock Sidekiq 7.3.10 + 8.1 hand to `Rails.error` for a failing job, a missing class, and a retry (parity harness, `bench/vs_sidekiq/Gemfile` has stock). (b) Match it exactly. (c) If stock also reports per attempt: keep, and document + add `Wurk::Sentry.configure_sdk(config)` that appends the control-flow + `RedisClient` exclusions three adopters hand-maintain. |
| R6 | P3 | `lib/wurk/sentry/error_handler.rb:37-38` | `Thread.current[REPORTED_ON_THREAD]` never cleared → last exception (backtrace, cause) pinned per processor thread. | Clear after the death-handler dedupe. |
| R7 | P2 | `lib/wurk/fetcher/reliable.rb:85`, `lib/wurk/leader.rb:289`, `lib/wurk/component.rb:72` | `ENV['DYNO'] \|\| Socket.gethostname` ×3. Divergence → private-list host ≠ reaper host → every local list looks foreign → recovery ~1s → ~91s. | `Component.hostname` everywhere. |

## Steps
1. R1+R2 together. Write the failing integration test first (below). New Lua goes in `lib/wurk/lua/` as a file (EVALSHA-cached via `Wurk::Lua::Loader`, pattern: `reaper.rb` `reclaim_one`). Keep the OOM path (`OomDrain.reclaim`) working: past maxmemory the job must still reach the public queue.
2. R3: extend `BootChecks`; reuse `locked_job_classes` walk (one `ObjectSpace` pass for both checks).
3. R4, R5: spec/oracle before code. A divergence gets its `docs/idea/parity-divergences.md` entry in the same PR.
4. R6, R7: mechanical.
5. Every PR: `bin/repin-anchors` on the PR's own tree; `bin/check`.

## Tests
- R1: `test/integration/` — consumer thread parked in `BLMOVE` on Q; private list of a dead owner holds J with counter at threshold; run `Reaper#drain`. Assert: consumer never receives J; J in `dead` exactly once; private list empty; death handler called once. Second case below threshold: J delivered once. Existing `test/unit/fetcher_reaper_test.rb:185-211` stays green.
- R2: counter key has TTL after a single `bump_counter` (real Redis).
- R3: unit — Worker + ActiveJob class with `unique_for`, no `unique!` → one WARN naming both; with `unique!` → silent.
- R5: `test/parity/` oracle file; R4: parity or unit per the spec outcome.
- R7: unit — the three call sites return `Component.hostname` under `DYNO` set/unset.
- `bin/rake test:parity`, `bin/check`.

## Done when
- R1 test fails on `f6f509e`, passes after; no job is ever both running and dead-set by the reaper.
- Boot WARN fires for the tesote.com shape (`unique_for` on an ActiveJob-style class, no `unique!`).
- `Rails.error` behaviour matches the stock oracle or has a ledger entry.
