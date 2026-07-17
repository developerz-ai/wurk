# 01 — Redis resilience (production incident fix)

> Part of [`overview.md`](overview.md). Depends on: none.

## Files to change

- `lib/wurk/redis_pool.rb` — split checkout vs socket timeouts; retry+backoff wrapper; telemetry hook.
- `lib/wurk/configuration.rb:498-505` — redis option pass-through; new defaults.
- `lib/wurk/capsule.rb:95-102,199-207` — pool sizing formula; wire `local_redis_pool` to the fetcher.
- `lib/wurk/fetcher/reliable.rb:130-139` — blocking BLMOVE moves to dedicated pool.
- `lib/wurk/swarm/child_boot.rb:73-82` — post-fork PING + eager script load.
- `lib/wurk/lua/loader.rb:20-39` — pipeline `script_load_all`; rescue connection errors in `eval_cached`.
- `lib/wurk/client/buffered.rb` — buffer on timeout errors, not just `ConnectionError`.
- `lib/wurk/scheduled.rb:53-63` — un-nest the drain checkout.
- `lib/wurk/component.rb:82-88` + callers (`cron.rb:526`, `metrics/rollup.rb:83`, `metrics/queue_rollup.rb:75`, `history.rb:95`) — cache `leader?` briefly.

## Steps

1. **Timeout split.** `RedisPool.new` gains distinct knobs: `pool_timeout` (ConnectionPool checkout, default keep 1.0), `connect_timeout` (1.0), `read_timeout` (**2.5**), `write_timeout` (2.5), `reconnect_attempts` (**1**). Kill the dual-use of `DEFAULT_TIMEOUT` (`redis_pool.rb:16,31,64`). Source of truth: `Configuration#redis_config` — accept and pass through the standard Sidekiq `config.redis = { url:, pool_timeout:, connect_timeout:, read_timeout:, write_timeout:, reconnect_attempts:, driver: }` hash so hosts can tune without new API. Unknown keys forward to `RedisClient.config` verbatim.
2. **Retry wrapper.** Rework `RedisPool#with` (`redis_pool.rb:34-48`):
   - Keep the existing `READONLY|NOREPLICAS|UNBLOCKED` close+retry.
   - Add bounded retry for `RedisClient::ConnectionError` (incl. `CannotConnectError`) and `RedisClient::ReadTimeoutError` / `WriteTimeoutError`: max 3 attempts, sleep `(0.5 * 2**attempt) + rand*0.25`, close the connection before retrying, then raise. Rationale: at-least-once semantics tolerate a rare duplicate; a raise into `JobRetry` today *already* re-runs the job, so retrying at the pool layer is strictly better.
   - `ConnectionPool::TimeoutError` is raised by `@pool.with` *before* the block — today it bypasses the rescue entirely. Catch it **outside** `@pool.with`, retry once after `0.1–0.3s` jittered sleep (pool may free momentarily), then raise. Do NOT loop — exhaustion needs the sizing fix, not queuing.
   - Emit through a new lifecycle/telemetry hook (see step 8) on every retry and final failure.
3. **Pool sizing.** Replace `POOL_OVERHEAD = 2` (`capsule.rb:95`) with the real consumer count: processors no longer use this pool for blocking fetch (step 4), so main pool = `concurrency + 5` floor 10 — covers heartbeat, poller, leader, cron, rollup ×2, reaper, history, health, plus job-code checkouts. Update the stale comment. Keep sizing overridable via `config.redis[:size]`.
4. **Dedicated fetch pool.** `Capsule#local_redis_pool` (`capsule.rb:101-102`) is built and never used — repurpose it as the **fetch pool** (size = `concurrency`, name `<cap>-fetch`) and route `Fetcher::Reliable#blmove` (`reliable.rb:130-139`) through it. Blocking BLMOVE no longer starves the main pool; idle == cheap again. The `blocking_call(timeout + 1, …)` read-window pattern stays as-is (it's correct). Delete `Configuration#local_redis_pool` (`configuration.rb:171-172`) if it remains unused after this.
5. **Post-fork validation.** In `ChildBoot#reconnect_after_fork` (`child_boot.rb:73-74`): after `reset_redis_pools!`, checkout once and `PING`; on failure retry via the step-2 wrapper (it now handles this). Then call `Lua::Loader.script_load_all` — the eager load `loader.rb:20` *claims* exists but doesn't (only caller today is the NOSCRIPT rescue at `client.rb:287`). Pipeline the loads (one round-trip, not 12).
6. **NOSCRIPT gap.** `Loader.eval_cached` rescue (`loader.rb:34-39`) only catches `CommandError`; a connection error during `SCRIPT LOAD`/retry propagates raw. Let the step-2 pool wrapper own connection retries; keep NOSCRIPT handling as-is on top.
7. **Buffered client gap.** `client/buffered.rb` rescues only `RedisClient::ConnectionError` — `ReadTimeoutError`/`TimeoutError` are not subclasses, so timed-out enqueues bypass the outage buffer. Broaden the rescue to the same transient set as step 2 (after the pool wrapper's retries are exhausted). Keep excluding `bid` payloads (`buffered.rb:314-317`).
8. **Observability.** New config-level hook, e.g. `config.on_redis_error` / lifecycle event `:redis_error` (`configuration.rb:31-40` pattern), fired by the pool wrapper with `{error:, attempt:, retried:, pool: name}`. Bump the default error handler's `INFO` to `WARN` for Redis-class errors (`configuration.rb:60-67`). Expose pool stats (`size`, `available`) via `RedisPool#info` for the heartbeat.
9. **Minor starvation trims.** `Scheduled::Enq#drain_set` (`scheduled.rb:53-63`) holds a checkout across the whole drain while `@client.push` nests a second — restructure to pop under one checkout, push outside it (or reuse the held conn via `Client#push` accepting a conn). Cache `Component#leader?` (`component.rb:82-88`) for ~5s to stop 4 background loops issuing a GET each tick.

## Tests

- Unit (`test/`): pool builds with split timeouts from `config.redis` hash; wrapper retries `CannotConnectError`/`ReadTimeoutError` with backoff then raises (stub `RedisClient` — this is unit, not integration, so stubbing is allowed); `ConnectionPool::TimeoutError` retried exactly once; hook fires with correct payload.
- Integration (real Redis, `test/integration/`): kill/pause Redis mid-run (e.g. `CLIENT PAUSE` or drop via toxiproxy-less `DEBUG SLEEP`), assert jobs neither fail nor duplicate and the process recovers without restart; BLMOVE runs on the fetch pool (assert main-pool `available` stays ≥ N while idle).
- Bench guard: `bin/rake bench` — enqueue + fetch/execute deltas <5%.
- Commands: `bin/rake test`, `bin/rake test:parity`.

## Done when

- Transient Redis blips (≤ ~4s) produce zero job failures — verified by the integration test.
- Idle worker holds 0 main-pool connections in BLMOVE; `0/N` exhaustion no longer reproducible with default config.
- Hosts can set `config.redis = { read_timeout: 5.0, reconnect_attempts: 2 }` Sidekiq-style and see it applied.
- `:redis_error` events observable; retries logged at WARN.
