# Verified non-findings — do not "fix" these

Reference for executors. Each was flagged as suspicious by an auditor and then verified correct. Churning them risks real bugs.

## Process / fork

- Swarm self-pipe across fork: child closes both ends pre-`ChildBoot` (`swarm.rb:188-189`); `emit_signal` rescues `IOError/EPIPE/EBADF` — trap-window writes are no-ops.
- Child closing a fork-shared Redis socket: `RedisClient#close` drops only the child's FD reference, no FIN — parent connection survives. Lazy `||=` rebuild is correct.
- `Backoff` state keyed by slot index, not PID — bounded by topology (`swarm/backoff.rb:25-26`).
- `Restart` queue self-heals stale PIDs (`restart.rb:131-134`); dedupes via `in_flight?` (`:44-50`); replacement claim gated on phase (`:62`); late reaps can't masquerade as crashes (`:155-167`).
- `@children` entries deleted on exit + cleared in `hard_kill_stragglers` — bounded (the *locking* is the bug, see 01).
- SIGKILLed old child during rolling restart loses no jobs — reaper's scoped sweep reclaims via `kill(0)` (until 02 changes the predicate — preserve this property).
- TSTP survives respawn via `start_quiet:` threaded through fork args — deliberately NOT a post-fork signal (trap-default suspend race).
- Un-retained `Thread.new` in `rails_boot.rb:118` — running threads aren't GC'd.
- `Health::Server` start/stop idempotence correct (`health.rb:56`); leaks only via 01/A2's missing ensure.
- `RedisPool#run` reuses one checked-out slot across retries — cannot leak checkouts.

## Execution / batch / Lua

- `Lua::SCRIPTS`/`SHAS` frozen at load; `eval_cached` allocation-free; NOSCRIPT recovery correct — there is no growing script cache.
- Middleware chain builds fresh instances per job by documented contract (`chain.rb:10-12`) — do not cache instances.
- All job-path thread-locals are save/restore with ensure: `Context.with`, `Batch#collect_jobs`, `Client.via`, `PoolScope`, `CurrentAttributes::Load`, `I18n::Server`.
- No bare `checkout` anywhere; `ConnectionPool` is thread-reentrant — recursive `Wurk.redis` in `Batch#cascade_invalidate` / `propagate_to_parent` reuses one conn (looks like exhaustion, is not).
- SSE: `drive_stream` ensures `sse.close`, 120 s hard cap, no per-connection threads/subscriptions/hijack.
- Periodic threads are `@thread ||=` singletons; `Cron.fire!` constructs a Poller but never starts it.
- All metrics/rollup keys carry TTLs; `stat:processed/failed` TTL-less by wire-compat design.
- Unique locks: `SET NX EX` + CAS-release Lua both paths.
- Web reads bounded: pagination clamps, `FILTER_SCAN_LIMIT`, search scan budget, ≤1000 bulk keys.
- `Concurrent#within_limit` releases in ensure; ZSET scores self-reclaim.
- Manager `@workers` under `@plock`, snapshot-then-iterate — correct.
- `Manager#hard_shutdown` cross-thread `Processor#job` read: racy but safe — `RELIABLE_REQUEUE` gates RPUSH on `LREM == 1`.
- Concurrent boot-reclaim across processes: single atomic `LMOVE` per payload — no duplication.
- `ack = true` + outer-ensure acknowledge (`processor.rb:167-186`) — byte-for-byte Sidekiq's at-least-once structure.
- `JobRetry` backoff math + `retry_for` exclusivity match spec §17 exactly (incl. `count**4 + 15`, 0-indexed 25 retries).
- `DeadSet#trim`'s apparent off-by-one is Sidekiq's exact call — wire parity.
- `Heartbeat#pipelined_beat` lead-offset arithmetic verified; entire beat is one pipeline (reference implementation).
- `BATCH_PUSH`/`BATCH_ACK_*` SADD-gated counters idempotent under re-push; ack-success clears failed-set before live-check — deliberate.
- `RELIABLE_SCHEDULE_PROMOTE` decode→lpush→zrem order + surgical `enqueued_at` string patch (avoids cjson double-precision corruption) — deliberate.
- Split pipelines in `Client#push_immediate`/`push_scheduled_split` — merging them reintroduces the NOSCRIPT-replay duplicate bug (comment on site).
- `Cron::Parser` TZ cache never touches `ENV['TZ']` (regression #210).

## Frontend / tests

- `useSSE` singleton refcount + `onCleanup`-in-`onMount` correct; native EventSource reconnect only — no stacking.
- `useSize` ResizeObserver disconnected; zero other observers/window listeners in `frontend/src`; Modal's `cancel` listener removed on cleanup.
- Search/FilterBox/useCountUp timers all cleaned (toast is the exception — 09/FE7).
- TanStack polling stops on route unmount; 5-min default gcTime bounds `['search', term]` accumulation.
- SimpleCov in test-forked children: `SimpleCov.pid` guard + per-worker `at_fork` — no corruption; `redis_options_fork_test` uses `exit!` belt-and-braces.
- All 23 explicit `RedisPool.new` sites in `test/` pair with `disconnect!`; forked test children close clients in ensure.
- `RedisNamespace#teardown` ensure-chains `super` — one broken test can't skip cleanup.
- `reaper_full_sweep_test` reaps its fork in teardown with ESRCH/ECHILD rescued.
- `bench/swarm_boot.rb` ensures per-sample shutdown + warmup boot (and note: it bypasses `Process.warmup`, understating shipped boot — bench-harness observation only).
- Dummy app boots once, no demo-workload thread under test env.

## Cross-cutting note (not a bug today)

Redis Cluster: `RELIABLE_SCHEDULE_PROMOTE` uses an undeclared key (`lua.rb:89`); `RELIABLE_REQUEUE`/`BATCH_PUSH` would CROSSSLOT. Nothing claims Cluster support; limiter scripts were reworked for it (#91), scheduler/fetch/batch were not. Record as known limitation if Cluster ever lands on the roadmap.
