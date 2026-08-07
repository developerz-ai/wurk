# 06 — Boot: 0.97s → ≤0.67s

> Part of [`overview.md`](overview.md). Depends on: none. Target: beat Sidekiq's boot-to-first-job (0.67s), measured by `bench/swarm_boot.rb:64-90` (2 children, waits for `:startup` RPUSH markers) and `bench/vs_sidekiq.rb:169-179`.

Sidekiq's boot = require app + one `INFO` + spawn threads (`sidekiq cli.rb:43-125`). Wurk pays: sequential forks, per-child Lua upload, AR reconnect, and 6 background loops started **before** managers.

## Files to change

- `lib/wurk/swarm.rb` — pre-fork Lua load, warmup, fork loop.
- `lib/wurk/swarm/child_boot.rb` — drop per-child Lua upload.
- `lib/wurk/launcher.rb` — start order: managers first, pollers after.

## Steps

1. **P11 — pre-fork Lua load.** `SCRIPT LOAD` is server-global; every child re-uploads all scripts on its boot-critical path (`child_boot.rb:133-138` → `lua/loader.rb:25-29`). Load once in `Swarm#boot` before forking; child keeps only the `PING` (connection liveness). Fallback intact: `eval_cached` already handles NOSCRIPT → re-upload, so a Redis restart between parent load and child use self-heals — verify that path has a test.
2. **Managers before pollers.** `Launcher#run` (`launcher.rb:88-102`) starts heartbeat, scheduled poller, leader, cron poller, metrics rollup ×2 before managers. Reorder: managers (fetch/execute) first, then heartbeat, then the rest — and give leader/cron/rollups a small initial delay (their existing `TimerLoop` cadences are 15-60s; nothing needs tick-zero at boot). First-job latency is what the bench measures. Keep the boot-reclaim thread early — it's correctness (kill-9 recovery), not decoration.
3. **`Process.warmup` before fork.** Sidekiq calls it pre-threads (`cli.rb:106`); for wurk it belongs in `Swarm#boot` right before `fork_children` — GC-compacts the warmed heap so children share more CoW pages (also a steady-state RSS win, shows in bench:memory indirectly). Confirm `Wurk.freeze!`/config freeze runs pre-fork (`configuration.rb:491` exists — check call site ordering), so no post-fork rehash unshares pages. Note: 07 fixes a `FrozenError` latent in `lookup` (`configuration.rb:246-248`) — freeze earlier only after that lands.
4. **Fork-loop measurement.** `fork_children` is sequential with `close_supervisor_pool` before each fork (`swarm.rb:246-248`, `:269`). Measure before touching: with step 1-3 done, per-fork cost should be ~ms. Only if the bench still shows fork-loop time: hoist the pool close out of the loop (it must run before the *first* fork; re-closing per fork is only needed if the supervisor used Redis between forks — it doesn't in the boot loop).
5. **Child-boot audit.** `child_boot.rb:46-63,108-123` runs traps, buffer reset, AR `establish_connection`, statsd reset, `:fork`/`:startup` events sequentially. AR reconnect is likely the big fixed cost — verify it's lazy (connection actually opened on first checkout) or make it so; don't block `:startup` on a DB handshake the noop bench never uses.

## Tests

- Existing: `test/integration/swarm_boot_test.rb` (the `:startup` marker), `swarm_supervision_test.rb`, `rolling_restart_test.rb`, `graceful_shutdown_test.rb`, `reaper_kill9_test.rb` (boot-reclaim must still run early).
- New: parent-loaded scripts usable in children (fork after load, EVALSHA works without re-upload); NOSCRIPT self-heal in child; launcher start-order (managers fetching before first poller tick — observable via a probe job completing before leader key exists).
- `bin/rake bench:swarm_boot` per commit; final `bin/rake bench:vs_sidekiq` boot column.

## Done when

- `bench:swarm_boot` mean improves ≥25% vs main; vs_sidekiq boot-to-first-job ≤0.67s.
- Rolling restart, supervision, kill-9 reclaim integration tests green.
- Full suite + coverage green.
