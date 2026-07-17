# 03 — Swarm supervision hardening

> Part of [`overview.md`](overview.md). Depends on: none (02 recommended first).

## Files to change

- `lib/wurk/railtie.rb:19-33` — auto-fork unsafe under Puma cluster / Unicorn.
- `lib/wurk/swarm.rb:32,60-73,86-99,136,147-176,190-204,228-234` — backoff, rolling restart, traps, reaping.
- `lib/wurk/swarm/child_boot.rb:70,94` — trap safety, USR1 disposition.
- `lib/wurk/health.rb:45-61` — port rebind after owner death.
- `lib/wurk/cli.rb:191-193` — SIGUSR2 log reopen missing in standalone path.
- `lib/wurk/launcher.rb:97-98` — boot_reclaim blocks readiness.

## Steps

1. **Railtie web-server guard** (highest architectural risk). `Railtie.skip_boot?` has no notion of "I am a web server". Detect and defer: if running under a preforking server (Puma cluster: `Puma.respond_to?(:cli_config)` / `$PROGRAM_NAME`, Unicorn, Passenger), do **not** boot the swarm from `after_initialize`. Options, in preference order: (a) register `Puma` `on_worker_boot`-independent hook is wrong (would fork per worker) — instead refuse + log an actionable error telling the host to run `exe/wurk`/`wurkswarm` as a separate process, unless `config.wurk.embed_in_web = true` explicitly opts into embedded threads-only mode (no fork, like Sidekiq embedded); (b) at minimum, guard with "am I the process that ran `rails server`" + not-preforking check. Never fork the swarm from a process that will itself fork. Document in README.
2. **Crash-loop backoff.** Replace flat `RESPAWN_BACKOFF = 1.0` inline `sleep` (`swarm.rb:174-176`): per-slot exponential backoff (1s → 2 → 4 … cap 30s) reset after a child survives ≥60s. Never `sleep` on the supervise thread — track `respawn_not_before` per slot and let the `SUPERVISE_TICK` loop skip until due. Fleet-wide mass death then recovers in parallel ticks, not serialized 1s sleeps (`swarm.rb:161` one-reap-per-tick: loop `reap_one_child` until `nil` each tick).
3. **Non-blocking rolling restart.** `rolling_restart` (`swarm.rb:86-99`) runs on the supervise thread for up to `N×55s`, blocking TERM and reaping. Restructure as a state machine advanced from the supervise loop: one slot in flight at a time; states `spawn_replacement → await_heartbeat(deadline 30s) → term_old → await_exit(deadline shutdown_timeout) → next slot`. TERM/INT received mid-restart aborts the sequence and enters normal drain. `wait_for_heartbeat` must also `waitpid(pid, WNOHANG)` so a crashed replacement is detected as dead, not "slow" (`swarm.rb:90-97,246`) — on replacement death: keep the old child, apply step-2 backoff, retry the slot.
4. **Orphan protection.** On Linux install `PR_SET_PDEATHSIG=SIGTERM` in the child right after fork (`child_boot`), guarded by a `getppid` check for the fork/exec race (if parent already changed, self-TERM). Portable fallback: a cheap parent watchdog thread in each child — `getppid` every 5s; if it changes (reparented), initiate graceful drain. Prevents doubled concurrency after a SIGKILL'd supervisor + redeploy.
5. **Trap safety.** `Signal.trap { @signal_queue << sym }` (`swarm.rb:136`, `child_boot.rb:94`) takes a mutex in trap context — swap to the self-pipe pattern the CLI already uses (`cli.rb:184`). Install parent traps **before** `fork_children` (`swarm.rb:60-62` window currently orphans children if TERM lands between fork and trap).
6. **Health port rebind.** `health.rb:45-61` binds once at boot; if the owning child dies, no probe until pod restart. Move health server ownership to the **parent** (supervisor answers for the swarm — it has heartbeat knowledge via `wait_for_heartbeat` machinery), or have non-owner children retry bind on a 5s timer. Parent-owned is architecturally right: liveness of supervisor + readiness aggregated across children.
7. **Small fixes.**
   - `child_boot.rb:70`: don't reset USR1 to DEFAULT (terminates child on stray signal) — trap as no-op with a log line.
   - `cli.rb:191-193`: add USR2 → log reopen to the standalone trap list (contract promised in CLAUDE.md signals table).
   - `launcher.rb:97-98`: run `boot_reclaim` on a background thread so `/ready` isn't delayed by a large orphan sweep; reaper drain already atomic (`reaper.rb:268`).
   - `child_boot.rb:73-82`: log at WARN when ActiveRecord reconnect fails instead of silent `rescue nil`.
   - Memory-pressure recycle (`swarm.rb:190-204`) is PID-based — fine, but route recycle TERMs through the step-3 state machine so recycle + rolling restart can't overlap on one slot.

## Tests

- Integration: crash-looping child (exit 1 in boot) → respawn intervals grow, supervise loop stays responsive to TERM (assert drain completes < timeout while a slot is in backoff).
- Rolling restart: kill the replacement mid-restart → old child survives, slot retried; TERM mid-restart → aborts to drain.
- Orphan: SIGKILL parent → children self-terminate within watchdog interval (fork-capable CI leg only).
- Railtie guard: unit-test `skip_boot?`/deferral matrix (console, test, WURK_DISABLED, puma-cluster detection stub).
- Commands: `bin/rake test` (integration layer runs real forks; keep out of JRuby leg).

## Done when

- No supervise-thread sleeps; TERM honored < 1s regardless of restart/backoff state.
- Crash-loop hits Redis/DB at bounded rate (cap 30s).
- SIGKILL'd parent leaves zero fetching orphans.
- Signals table in CLAUDE.md is accurate for swarm, standalone, and child paths.
