# 10 — Test & bench hygiene

> Part of [`overview.md`](overview.md). Depends on: none. Fixes real flake sources and a destructive-bench hazard; no `lib/` changes.

## Files to change

- `test/integration/liveness_probe_test.rb:24-48` — unstopped Launcher (T1)
- `test/test_helper.rb:102-111` + `test/engine_test_helper.rb:9-13` — AR handle across parallel fork (T2)
- `test/unit/processor_test.rb:29-38` — processor teardown (T3)
- `test/integration/{swarm_boot,swarm_supervision,reaper_kill9,periodic_leader,batch_nested_callbacks,batch_retry_roundtrip,scheduled_promotion}_test.rb` — supervisor join/kill + boot inside ensure (T4, T5)
- `bench/enqueue.rb`, `bench/bulk_enqueue.rb`, `bench/scheduled_poll.rb` — DB isolation (T9)
- `test/integration/redis_outage_recovery_test.rb:222-267` — BlipProxy pump threads (T12)
- `test/test_helper.rb:110` — bounded `Process.waitall` (T11)

## Steps

1. **T1 (flake source) — `liveness_probe_test` never stops its Launcher.** 4 tests × full Launcher (processors on `queue:default`, poller, leader, rollups, 2 pools) leak per worker; zombie launchers steal later tests' `queue:default` jobs. Fix: `teardown` → `@launcher&.stop rescue StandardError`, bounded thread joins; switch the test to a unique per-test queue name so any survivor can't poach.
2. **T2 — parallel-fork workers share the parent's SQLite connection.** `engine_test_helper` boots dummy + `rails/test_help` (opens `test/dummy/db/test.sqlite3`) in the parent; `after_parallel_fork` resets Redis only. Mirror `Swarm#close_parent_sockets`: in the hook, `ActiveRecord::Base.connection_handler.clear_all_connections!` guarded by `defined?(::ActiveRecord::Base)`.
3. **T3 — processor threads outlive failed assertions.** `processor_test` teardown never touches `@processor`; a failure before the in-test `terminate` leaves a BLMOVE loop that can ack after `FLUSHDB`. Track created processors; teardown drains with `kill(true)`/bounded join before key cleanup.
4. **T4 — `supervisor&.join(N)` without kill-on-timeout; `reap_children` does `Process.wait2(-1)`** — a surviving supervise thread reaps *other tests'* forked children (ECHILD flakes). At every site: `ensure swarm.shutdown(...) rescue nil; supervisor&.join(10) || supervisor&.kill`. (The unscoped `wait2(-1)` itself is `lib/` behavior — leave it; killing the thread closes the hazard.)
5. **T5 — `swarm.boot` outside begin/ensure** at `swarm_boot_test.rb:56-58`, `reaper_kill9_test.rb:71-73`, `swarm_supervision_test.rb:47-49`: partial-boot children escape the `ensure shutdown`. Move boot + supervise-thread creation inside the `begin`.
6. **T9 (destructive) — `bench/enqueue.rb`, `bulk_enqueue.rb`, `scheduled_poll.rb` run against default DB 0** and `DEL queue:default schedule retry` — wipes a dev's real data and makes the >5% merge gate noisy (any local worker drains the bench queue). The other three benches already pin DBs 13/14/15 for exactly this reason (#258/#259). Hoist `bench_redis_url` into shared `bench/support.rb`; pin these three to unused DBs (11/12/10); keep pre/post cleanup scoped there.
7. **T11 — coverage-mode `Process.waitall` unbounded**: replace with WNOHANG poll loop + deadline that fails loudly listing unreaped PIDs.
8. **T12 — BlipProxy pump threads untracked**: push client socket into `@sockets` before opening upstream; collect pump threads; join in `stop!`.

## Tests

- The changes ARE tests — verification is the suite itself: run `bin/rake test` 3× consecutively in one process tree; no cross-test job theft, no ECHILD flakes, worker exit clean.
- `bin/rake bench` on a Redis with seeded DB 0 data → data intact afterward; bench numbers stable across two runs within noise.
- Coverage gate unaffected (no `lib/` change).

## Done when

- Full parallel suite green repeatedly; leaked-thread/process count at suite end is zero (assert via a final `Minitest.after_run` check if cheap).
- No bench touches DB 0; all six benches share the isolation helper.
