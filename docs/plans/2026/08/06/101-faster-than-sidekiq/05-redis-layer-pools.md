# 05 — Redis layer: adapter tax, checkout frames, pool reuse

> Part of [`overview.md`](overview.md). Depends on: none (disjoint files). Every win here multiplies across all commands (~10/job today, ~2 after 02).

## Files to change

- `lib/wurk/redis_client_adapter.rb` — per-command odometer tax.
- `lib/wurk/redis_pool.rb` — `run` frame cost.
- `lib/wurk/pool_checkout.rb` — checkout frame + type check.
- `lib/wurk/fetcher/reliable.rb:222` — only the timeout padding line (coordinate with 02, which owns the rest of that file — land 02 first or rebase).

## Steps

1. **Odometer granularity.** `CompatClient` redefines every dispatch method to `super` + `@round_trips += 1` (`redis_client_adapter.rb:100-113`) — an extra frame + ivar write on *every* command, including each command inside a pipeline. The odometer exists for the pool's replay-safety proof (`redis_pool.rb:196-198`). Verify what that proof actually needs: if it's round-trip granularity, increment only in `call`/`blocking_call`/`pipelined`/`multi` at top level (1 per RTT, not per command) and delete the per-command wrappers. If per-command is required, make the increment the *only* added cost (no extra begin/rescue, no arg churn).
2. **`method_missing` audit.** Grep the adapter for `method_missing` fallthrough on hot commands. Every command used in a hot path (LMOVE, BLMOVE, LREM, LPUSH, SADD, HINCRBY, EVALSHA, SMEMBERS, DEL, ZADD) must be a real defined method — Sidekiq's `USED_COMMANDS` trick (`sidekiq redis_client_adapter.rb:23-37`). Define any missing ones.
3. **Checkout frame diet.** Per checkout today: `PoolCheckout.with` (`is_a?(RedisPool)` check, `pool_checkout.rb:23-27`) → `RedisPool#run` (odometer snapshot + begin/rescue, `redis_pool.rb:191-209`). ×4/job pre-02, ×1-2 after. Cache the pool-type decision at the call sites that always pass a `RedisPool` (most of `lib/`); keep the polymorphic path for user-supplied pools. Fold `run`'s snapshot into the retry branch so the happy path is `pool.with { yield }` + one ivar read.
4. **Kill the manual timeout padding.** `reliable.rb:222` passes `timeout+1` as socket read timeout; redis-client already adds `config.read_timeout` to blocking calls (`redis-client-0.28.0 connection_mixin.rb:85-91`). Verify wurk's `blocking_call` route hits that codepath, then drop the manual padding.
5. **Pool-reuse audit (busy path).** After 02, the busy-path RTT is one pipelined LREM+LMOVE. Decide which pool owns it: the fetch pool is sized `concurrency` (`capsule.rb:109-111`) and exists exactly so parked fetchers don't starve the main pool — route the combined fetch+ack RTT there, leaving the main pool to heartbeat/pollers. Confirm main pool sizing (`concurrency+5` floor 10) still fits the post-02 command mix; document the ownership in the capsule.
6. **Config parity check.** Confirm RESP3 (redis-client default), `reconnect_attempts: 1`, `timeout: 3` match Sidekiq's (`sidekiq redis_connection.rb:33`, `redis_client_adapter.rb:108`). Don't add hiredis — same-for-both, not a differentiator (and a new dependency).

## Tests

- Existing: `test/unit/*redis_pool*`, adapter tests, `test/integration/redis_outage_recovery_test.rb` (the replay-safety proof the odometer serves — must stay green with the new granularity).
- New: odometer semantics under pipelining (whatever granularity step 1 lands, assert it); every hot command resolves without `method_missing` (`respond_to?` without `include_private` or a dispatch spy).
- `bin/rake bench:fetch_execute` + `bench:enqueue` per commit.

## Done when

- Zero per-command wrapper overhead beyond one ivar increment per round trip (or documented reason why per-command is required).
- No `method_missing` dispatch on any hot-path command.
- Outage-recovery integration test green; full suite + coverage green.
