# 07 — Leaks and resource lifecycle (RAII gaps)

> Part of [`overview.md`](overview.md). Depends on: 06 (shares `swarm.rb`/`launcher.rb` — land 06 first or coordinate). Findings from the 2026-08-06 lifecycle audit; items marked (S*) were already known-open in `docs/plans/2026/07/31/101-leak-logic-perf-fixes/` slice 07 — this slice closes them.

## Files to change

| file:line | sev | defect → fix |
|---|---|---|
| `lib/wurk/swarm.rb:357` | **high** (embedded) | `Process.wait2(-1, WNOHANG)` reaps *any* child — in embedded `boot_swarm` mode the supervise tick steals exit statuses of the host's own subprocesses (Puma workers, `system`/`Open3`) → host gets `ECHILD`. Fix: reap only known pids — loop `@children.each_key { Process.wait2(pid, WNOHANG) }`. |
| `lib/wurk/swarm.rb:472-477` | med | `hard_kill_stragglers` SIGKILLs then `@children.clear` with no final reap → permanent zombie per straggler when the host process lives on. Fix: `wait2(pid, WNOHANG)` sweep (bounded retries) after the kills, before clear. |
| `lib/wurk/launcher.rb:339` | med | Embedded TERM spawns an unretained, unjoined `Thread.new { stop }` per signal; N concurrent stops race `release_components`. Fix: single-shot guard (atomic flag) + retain and join the stopper. |
| `lib/wurk/fetcher/reaper.rb:99`, `lib/wurk/leader.rb:145` | med | Unbounded `thread.join` in `stop` — the reaper's full-keyspace SCAN is exactly the tick that overruns, blowing the parent's `SHUTDOWN_GRACE` → child SIGKILLed mid-drain. Fix: bound both at `TimerLoop::JOIN_TIMEOUT` (5s) like every other periodic component (`launcher.rb:221-223` callers). |
| `app/controllers/concerns/wurk/stream_concurrency_guard.rb:22-33` | med (S13) | SSE slot counter never self-heals if a Puma thread is hard-reaped mid-stream (skips `ensure` at `:50`); 10 leaks = permanent 503 on `/api/stream`. Fix: slot registry keyed by thread ref, sweep dead threads on acquire. |
| `lib/wurk/launcher.rb:137,139` | low-med | `stoppers.each(&:join)` unbounded; wedged Redis in `fetcher.terminate`/`bulk_requeue` adds ~10s past the deadline. Fix: join with remaining-deadline budget. |
| `lib/wurk/processor.rb:250` | low-med (S9) | `WORK_STATE.set` outside the `begin`/`ensure` at `:251-259` — a non-Shutdown async raise in the window pins the job entry (payload string retained, `busy` inflated forever). Fix: move the `set` inside, or wrap set+block in its own `ensure WORK_STATE.delete(tid)`. |
| `lib/wurk/middleware/poison_pill.rb:132-137` | low-med (S11) | `on_poison` append-only module registry, no dedup/deregistration — re-run initializers accumulate closures retaining their bindings. Fix: return a handle for removal + dedup by callable identity; document. |
| `lib/wurk/heartbeat.rb:193,205` | low | `File.foreach(path).find { }` abandons the enumerator FD until GC. Fix: `File.open` block + internal find, or force `.close` on the enumerator. Bounded by `@host_facts` memo — 1 FD per instance, still fix. |
| `lib/wurk/web/config.rb:205-213` | low (S10) | `rack_app` memo ignores `inner` — first caller's inner app pinned forever. Fix: key memo on `[inner, @middlewares]` or drop memo. |
| `lib/wurk/client/buffered.rb:115-122` | low | `reset!` swaps buffer but never stops `@drainer` — surviving thread ticks against nil'd factory. Fix: `@drainer&.stop` inside `reset!`. Test-only entry today; still a footgun. |
| `lib/wurk/launcher.rb:208` | low | `reset_redis_pools!` only when `@embedded` — direct `Launcher` drivers (rake/tests) leak every capsule pool's sockets on stop. Fix: always reset on stop; idempotent. |
| ~~`lib/wurk/configuration.rb:246-248`~~ | ~~low~~ | **Landed in 06 step 3** — it blocked the earlier freeze, so it shipped with it. `freeze!` no longer freezes `@directory` (the lazily-filled `lookup` memo), and `prepare_for_fork!` materializes the default capsule before `@capsules` closes, so the same FrozenError can't hit `default_capsule` either. |

Not worth acting on: `lib/wurk/cron.rb:239` tz cache (bounded by config).

## Already correct — do not re-do

Checkout/checkin via `ConnectionPool#with` owns the ensure (`redis_pool.rb:124,191-209` — retry reuses the same slot, no leak path). Pre-fork close is thorough (`swarm.rb:231-243` → `configuration.rb:192-196`; self-pipe, dogstatsd, buffered client all covered). Outage buffer bounded at 1000, drop-oldest (`buffered.rb:14`). Periodic threads join bounded via `TimerLoop::JOIN_TIMEOUT` (except the two named above). SSE has no registry/hijack; streams close in `ensure` with 120s cap. Lua caches frozen. Thread-locals restore in `ensure`.

## Steps

1. Fix in severity order, one commit each, top table row → bottom.
2. For `swarm.rb:357`: add an integration test in which the swarm parent also spawns a non-swarm child and successfully `Process.wait`s it while supervise ticks.
3. For the join bounds: unit-test with a stubbed slow tick, assert `stop` returns within budget.
4. For `processor.rb:250`: test via `Thread#raise` injection between set and begin (deterministic seam: extract the window into a method you can intercept).

## Tests

- Existing: `test/integration/swarm_supervision_test.rb`, `graceful_shutdown_test.rb`, `rolling_restart_test.rb`; unit tests per touched class.
- New per finding as in Steps. Retention probe for WORK_STATE/poison-pill fixes lands in 08 (bench-side).
- `bin/rake test` + coverage ≥90/90 (several fixes add branches — cover both arms).

## Done when

- Every table row fixed or waived in writing; new tests prove each fix.
- No zombie children in embedded mode; `stop` bounded end-to-end; no unbounded module-level registries.
