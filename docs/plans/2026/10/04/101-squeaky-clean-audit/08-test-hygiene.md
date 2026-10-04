# 08 — Test hygiene + confidence (closes #522, #486)

> Part of [`overview.md`](overview.md). Depends on: none. Diff for #522 must touch `test/**` only.

## #522 — timing-sensitive tests (remaining two)

- `LimiterStressTest` already fixed by #535 (`308bdd7`).
- `WebExtensionsTest`: `test/engine/web_extensions_test.rb:189` seeds `Time.now.to_f` → a leaked scheduler pops it. Seed `Time.now.to_f + 3600` (precedent: #520, `test/engine/api_mutations_test.rb:302-305`).
- `WebSearchTest`: `test/unit/web_search_test.rb:183-185` hard bound 2+100 assumes one queue; `search_queues` (`lib/wurk/web/search.rb:86-99`) walks shared `queues` set. Extend `RoundTripCounter` (`:258-272`) to record command+key; assert ≤101 calls against `queue:#{@queue}`. Add case: thread adds sibling queues during search. Don't touch `SCAN_LIMIT_PER_QUEUE` / `QUEUE_PAGE`.
- Also flaky on main (not in #522): `test/unit/web_search_test.rb:347` (retry entries scored now → poller promotes) and `test/engine/api_mutations_test.rb:143` (count 0, cause unknown). Score fixtures in future; add teardown assertion that no poller/scheduler threads leaked (`Thread.list` filtered by name) — this kills the whole class.

## #486 — `SimpleJob` TODO

- `test/dummy/app/jobs/simple_job.rb:7-9`: `perform` → `Wurk.redis { |c| c.call('SET', "simple_job:#{args.first}", Process.pid, 'EX', 60) }`.
- New `test/engine/active_job_roundtrip_test.rb` (`EngineCase`): `Wurk::Testing.inline!`, `SimpleJob.perform_later("t-#{SecureRandom.hex(4)}")` → key == `Process.pid`. Explicit teardown `DEL` (`test/engine_test_helper.rb:18` doesn't flush).

## Sleep-as-barrier cleanup
- `test/unit/launcher_test.rb:450,465`, `test/unit/leader_test.rb:530`: replace `sleep 0.1` barriers with condition waits (they pass vacuously under load).
- Clock-coupled: `api_throttle_test.rb:83`, `limiter_window/leaky/points` tests — inject clock or widen with progress-based assertions (pattern from #535).
- 119 `sleep` calls total; most are poll-until-deadline — leave those.

## Coverage honesty
- `test/test_helper.rb:6-16`: add `track_files 'lib/**/*.rb'` so unloaded lib files count. Expect line % to drop; fix gaps to stay ≥90/90 (currently 97.67 / 92.58).

## Parity oracle expansion (prod confidence)
- `test/parity/` = 3 files, 23 runs (job_retry, scheduled, sorted_entry). Required check covers almost nothing. Add independently written oracles (from upstream behaviour at `test/parity/.sidekiq_sha`, spec in `docs/target/`) for: client push JSON shape (`jid`, `created_at`, `enqueued_at` units, `class`, `queue`, `retry`), reliable fetch/requeue, batch callbacks (success/complete/death, nested), limiters (concurrent/bucket/window/leaky), unique jobs, API (`Queue`, `RetrySet`, `DeadSet`, `ProcessSet`, `Stats`), cron. One file each; independently written = don't read Wurk impl while writing.

## Done when
- #522, #486 closed.
- 20 consecutive `bin/check` runs on the self-hosted runner with zero flakes (loop script in scratch, results in PR body).
- Parity suite ≥10 files; coverage gate holds with `track_files`.
