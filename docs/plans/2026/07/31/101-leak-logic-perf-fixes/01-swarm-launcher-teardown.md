# 01 — Swarm / Launcher teardown & fork hygiene

> Part of [`overview.md`](overview.md). Depends on: none.

## Files to change

- `lib/wurk/rails_boot.rb:113-114, 118-122, 128-137` — at_exit ordering, embedded partial-boot rollback
- `lib/wurk/swarm.rb:108, 197-215, 225, 242-254, 331-351` — owner-pid guard, `@children` locking, USR2 self-reopen, self-pipe close
- `lib/wurk/swarm/child_boot.rb:107-111` — statsd reset after fork
- `lib/wurk/launcher.rb:100, 122-141, 233-260` — stop ensure, boot-reclaim thread, heartbeat condvar
- `lib/wurk/manager.rb:102-109` — spawn-failure drain path
- `lib/wurk/cli.rb:108, 131-149` — `ensure @swarm&.shutdown`
- `lib/wurk/history.rb:74-79`, `lib/wurk/metrics/rollup.rb:62-66`, `lib/wurk/metrics/queue_rollup.rb:54-58`, `lib/wurk/scheduled.rb:160-177` — TimerLoop join/clear on terminate
- `lib/wurk/embedded.rb:53` / `lib/wurk/configuration.rb:191` — pool disconnect on embedded stop

## Steps

1. **A1 (critical) — child-inherited `at_exit` SIGKILLs siblings.** `rails_boot.rb:113` registers `at_exit { swarm.shutdown }` after initial fork; later respawn/recycle/rolling-restart forks inherit it, and `ChildBoot#run`'s `exit 0/1` (`child_boot.rb:63,66`) runs it inside the child → `relay_signal('TERM')` + 30 s `wait_for_children` stall + `hard_kill_stragglers` SIGKILLs live siblings. Fix: capture `@owner_pid = ::Process.pid` in `Swarm#boot`; `shutdown`/`supervise`/`relay_signal`/`hard_kill_stragglers` no-op unless `::Process.pid == @owner_pid`. Belt-and-braces: move the `at_exit` registration before `swarm.boot`.
2. **A3 — `@children` race.** Supervise thread + at_exit thread both mutate `@children` unsynchronized; `relay_signal`/`hard_kill_stragglers` iterate `each_key` without `dup` (contrast `check_memory_pressure` swarm.rb:308 which does). Either add a Monitor around `@children` + restart machine, or (simpler, preferred) make `at_exit` set a flag the supervise thread observes so `shutdown` never runs off-thread. Fix the two `each_key` sites regardless.
3. **A2 — `Launcher#stop` has no ensure.** `stoppers.each(&:join)` (`launcher.rb:127`) re-raises from `Manager#stop` → skips terminating `@cron_poller`/`@metrics_rollup`/`@queue_rollup`/`@history`, `@reaper.stop`, `@leader.stop` (leader lock never CAS-released), heartbeat clear, `@health_server.stop` (TCPServer FD leak). Wrap: rescue per-stopper inside the stopper threads; `ensure` around the full teardown tail.
4. **A4 — embedded partial boot leaks everything.** `rails_boot.rb:128-137`: register `at_exit { instance.stop }` *before* `instance.run`; make `Embedded#run`/`Launcher#run` roll back (call `stop`) when boot raises partway — otherwise ~8 threads + 2 pools + health TCPServer + a renewing leader lock leak inside the web process.
5. **A7 — Manager spawn-failure bypasses drain.** `manager.rb:102-109` `main_thread.raise(e)` unwinds to `ChildBoot#run` rescue → `exit 1`, skipping `bulk_requeue`. Route through the child's self-pipe TERM path instead of raising into `Thread.main`.
6. **A5 — parent never reopens own log on USR2.** `swarm.rb:225`: `when :usr2 then reopen_logs; relay_signal('USR2')` — mirror `ChildBoot#reopen_logs` (`child_boot.rb:194`). Only bites file-backed loggers (stdout reopen is a no-op).
7. **A6 — statsd socket bleeds across fork.** Add `Wurk::Metrics::Statsd.reset!` to `ChildBoot#reconnect_after_fork` (`child_boot.rb:107-111`); `statsd.rb:103-107` documents this exact requirement, nothing in `lib/` calls it.
8. **A8 — pools never disconnected on embedded stop.** Add `@config.reset_redis_pools!` (or non-terminal `disconnect!`) to `Launcher#stop` teardown tail / `Embedded#stop` — stop-then-run in Puma currently doubles the socket set.
9. **A9 — `@boot_reclaim_thread` unmanaged.** `launcher.rb:100`: retain the thread; `stop` joins with deadline or sets a cancellation flag `Reaper#reclaim!` checks per iteration.
10. **A12 — TimerLoop components: `terminate` never joins, never clears `@thread`.** Copy the correct pattern from `Leader#stop` (`leader.rb:121-128`) / `Reaper#stop` (`reaper.rb:93-100`) into History / Rollup / QueueRollup / Scheduled::Poller — join with deadline, nil the ivar so restart isn't a silent no-op.
11. **F11 — `stop_heartbeat` wakeup race.** `launcher.rb:233-260`: `Thread#wakeup` is lost if the beat is mid-Redis-call → ghost identity in `processes` for 60 s. Replace `sleep BEAT_PAUSE` with Mutex+ConditionVariable (TimerLoop pattern), then join without timeout.
12. **A10/A11 — self-pipes + traps.** `Swarm#shutdown` closes `@signal_read`/`@signal_write`; `CLI#run_swarm` gets `ensure @swarm&.shutdown`; close `self_read`/`self_write` in CLI exit paths.
13. **A13 (low)** — supervisor heartbeat polling (`heartbeat_seen?` → parent main pool reopened) — use a dedicated size-1 pool disconnected before each `Process.fork`, restoring the boot-ordering invariant (CLAUDE.md steps 3/5).

## Tests

- Integration: respawned child exiting normally must NOT TERM/KILL siblings (fork a 2-child swarm, crash one, let respawn exit, assert sibling alive). Covers A1.
- Unit: `Launcher#stop` with a Manager whose `stop` raises → assert leader released, heartbeat cleared, health server closed. Covers A2.
- Unit: embedded `run` with health-server bind failure → assert no live threads / pools after. Covers A4.
- Unit: TimerLoop components — `terminate` then `start` runs again (thread cleared). Covers A12.
- Commands: `bin/rake test`, `bin/rake test:parity` (signal semantics §21.3 untouched — TSTP stays one-way).

## Done when

- Kill-one-child-then-respawn-then-exit scenario leaves siblings running; no 30 s stalls.
- `Launcher#stop` teardown tail always executes under injected Redis errors.
- Embedded stop→run cycle holds socket count flat.
- Coverage gate holds; swarm-boot bench within 5%.
