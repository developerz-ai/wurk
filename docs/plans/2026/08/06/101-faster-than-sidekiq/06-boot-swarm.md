# 06 — Boot: 0.97s → ≤0.67s

> Part of [`overview.md`](overview.md). Depends on: none. Target: beat Sidekiq's boot-to-first-job (0.67s), measured by `bench/swarm_boot.rb:64-90` (2 children, waits for `:startup` RPUSH markers) and `bench/vs_sidekiq.rb:169-179`.

Sidekiq's boot = require app + one `INFO` + spawn threads (`sidekiq cli.rb:43-125`). Wurk pays: sequential forks, per-child Lua upload, AR reconnect, and 6 background loops started **before** managers.

## Files to change

- `lib/wurk/swarm.rb` — pre-fork Lua load, warmup, fork loop.
- `lib/wurk/swarm/child_boot.rb` — drop per-child Lua upload.
- `lib/wurk/launcher.rb` — start order: managers first, pollers after.

## Steps

1. **P11 — pre-fork Lua load.** `SCRIPT LOAD` is server-global; every child re-uploads all scripts on its boot-critical path (`child_boot.rb:133-138` → `lua/loader.rb:25-29`). Load once in `Swarm#boot` before forking; child keeps only the `PING` (connection liveness). Fallback intact: `eval_cached` already handles NOSCRIPT → re-upload, so a Redis restart between parent load and child use self-heals — verify that path has a test.
   - **Measured and REVERSED.** Shipped as written, then the bench gate caught it: `bench:swarm_boot` **152 → 95 i/s (−36.7%)** on CI (base 145/156/155, head 98/97/93 over 3 runs each), with the label's spread widening from ±2-6% to ±25-35%. Cause: step 3 (`close_parent_sockets`) has just closed every parent socket, so the pre-fork upload must open its *own* connection — phase-instrumented against real Redis, that connect + 25 pipelined `SCRIPT LOAD`s costs ~2.0ms of a ~10.5ms 2-child boot, serially, ahead of the first fork. What it replaced was cheaper, not dearer: children reconnect *in parallel*, so their uploads overlap each other. Counting connections, the "optimization" went from 2 (one per child, concurrent) to 3 (one serial parent + two concurrent children).
   - **Landed instead:** the upload stays in the child and now rides in the pipeline of the liveness `PING` it already sends, so a child pays **one** round trip for its whole Redis validation where it used to pay two (`ChildBoot#validate_redis!` → `Lua::Loader.queue_script_loads`). Strictly cheaper than the pre-fork variant *and* than the original per-child pair. `Swarm#boot` is now free of Redis entirely — pinned by `test_boot_puts_no_redis_round_trip_on_the_fork_path` and `test_boot_completes_without_a_reachable_redis` so the pessimization can't come back.
2. **Managers before pollers.** `Launcher#run` (`launcher.rb:88-102`) starts heartbeat, scheduled poller, leader, cron poller, metrics rollup ×2 before managers. Reorder: managers (fetch/execute) first, then heartbeat, then the rest — and give leader/cron/rollups a small initial delay (their existing `TimerLoop` cadences are 15-60s; nothing needs tick-zero at boot). First-job latency is what the bench measures. Keep the boot-reclaim thread early — it's correctness (kill-9 recovery), not decoration.
3. **`Process.warmup` before fork.** Sidekiq calls it pre-threads (`cli.rb:106`); for wurk it belongs in `Swarm#boot` right before `fork_children` — GC-compacts the warmed heap so children share more CoW pages (also a steady-state RSS win, shows in bench:memory indirectly). Confirm `Wurk.freeze!`/config freeze runs pre-fork (`configuration.rb:491` exists — check call site ordering), so no post-fork rehash unshares pages. Note: 07 fixes a `FrozenError` latent in `lookup` (`configuration.rb:246-248`) — freeze earlier only after that lands.
4. **Fork-loop measurement.** `fork_children` is sequential with `close_supervisor_pool` before each fork (`swarm.rb:246-248`, `:269`). Measure before touching: with step 1-3 done, per-fork cost should be ~ms. Only if the bench still shows fork-loop time: hoist the pool close out of the loop (it must run before the *first* fork; re-closing per fork is only needed if the supervisor used Redis between forks — it doesn't in the boot loop).
   - **Measured (real Redis, phase-instrumented boot, median of 3×8-child runs):** `close_supervisor_pool` is 0.01-0.07ms/call; `Process.fork` itself is ~1-2ms/child and is what the loop's time is. `bin/rake bench:swarm_boot` (2 children): 77 i/s (±20.6%, noise consistent with prior sessions' bench-noise findings for this label) ≈ 13ms/boot, well under the fork cost that would make a ~0.05ms save visible. **Not hoisted** — the trigger condition ("bench still shows fork-loop time") wasn't met. Comment left in `swarm.rb#fork_children` with the numbers so this isn't re-measured from scratch.
5. **Child-boot audit.** `child_boot.rb:46-63,108-123` runs traps, buffer reset, AR `establish_connection`, statsd reset, `:fork`/`:startup` events sequentially. AR reconnect is likely the big fixed cost — verify it's lazy (connection actually opened on first checkout) or make it so; don't block `:startup` on a DB handshake the noop bench never uses.
   - **Measured:** `establish_connection` is ~0.3ms warm (a one-time adapter-load cost is paid once, pre-fork, in the parent — inherited COW by every child) and `ConnectionPool#stat[:connections]` reads 0 immediately after — confirms AR already defers the real handshake to the first `.connection` checkout on a job thread, same as it always has. **No change needed.** Pinned by a new unit test (`test_reconnect_active_record_does_not_eagerly_open_a_connection`, `test/unit/child_boot_test.rb`) rather than left as an eyeballed assumption.

## Tests

- Existing: `test/integration/swarm_boot_test.rb` (the `:startup` marker), `swarm_supervision_test.rb`, `rolling_restart_test.rb`, `graceful_shutdown_test.rb`, `reaper_kill9_test.rb` (boot-reclaim must still run early).
- New: parent-loaded scripts usable in children (fork after load, EVALSHA works without re-upload); NOSCRIPT self-heal in child; launcher start-order (managers fetching before first poller tick — observable via a probe job completing before leader key exists).
- `bin/rake bench:swarm_boot` per commit; final `bin/rake bench:vs_sidekiq` boot column.

## Done when

- `bench:swarm_boot` mean improves ≥25% vs main; vs_sidekiq boot-to-first-job ≤0.67s.
- Rolling restart, supervision, kill-9 reclaim integration tests green.
- Full suite + coverage green.
