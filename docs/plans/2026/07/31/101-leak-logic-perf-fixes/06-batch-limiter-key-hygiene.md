# 06 — Batch / limiter Redis key hygiene

> Part of [`overview.md`](overview.md). Depends on: none.

## Files to change

- `lib/wurk/batch.rb:53, 172-181, 281-287` — sub-key TTLs, KEY_SUFFIXES, callback append
- `lib/wurk/batch/callbacks.rb:54, 74-88, 111-117` — dead-batches trim, dedup-key ordering
- `lib/wurk/batch_set.rb:29-38` — iteration over dead members
- `lib/wurk/lua.rb:269-283` — `BATCH_APPEND_CALLBACK` cap/dedup
- `lib/wurk/limiter/base.rb:107-118` — `lmtr-list` growth
- `lib/wurk/web/enterprise.rb:28-55`, `app/controllers/wurk/api_controller.rb:169-189` — read-side effects

## Steps

1. **S4 — batch sub-keys have no TTL.** `pipelined_first_flush` (`batch.rb:281-287`) EXPIREs only `b-<bid>`; `-jids/-failed/-died/-kids/-pkids` get TTLs only on `:success` or death. Abandoned/invalidated batches leak `-jids` members forever. Fix: `EXPIRE <key> <DEFAULT_EXPIRY_SECONDS> NX` for every `Batch.keys_for(bid)` key in the first-flush pipeline and in `BATCH_PUSH`'s key-creating paths (NX so linger/death restamps still win).
2. **S5 — `batches` ZSET never trimmed** (`ZADD batches` at `batch.rb:284`; only `ZREM` is manual `Status#delete`). Fix: on-write two-axis trim exactly like `DeadSet` (`dead_set.rb:40-41`) — `ZREMRANGEBYSCORE` older than `DEFAULT_EXPIRY_SECONDS`, `ZREMRANGEBYRANK` cap. Score is creation time (existing format — do not change).
3. **S7 — `dead-batches` same disease** (`callbacks.rb:54`). Same trim on write.
4. **S8 — `BATCH_APPEND_CALLBACK` unbounded + no dedup** (`lua.rb:269-283`): reopen-batch `#on` per job → O(N²) Lua work + N duplicate callback fires. Fix inside the Lua: skip append when an identical encoded `[event, target, options]` triple exists; hard-cap array length (e.g. 1000) with a returned flag the Ruby side logs on drop.
5. **F16 — callback dedup key burned before enqueue** (`callbacks.rb:74-88`): crash between `SET NX` and `enqueue_callbacks` permanently loses the `:success`/`:complete` callback. Reorder: enqueue first, then set the dedup key; on dedup-set failure after a successful enqueue, at-least-once duplicate callback is the acceptable direction (batch callbacks must tolerate retry anyway — they're jobs). Also add `complete`/`success`/`death` to `KEY_SUFFIXES` (`batch.rb:53`) so `Status#delete` and `apply_linger` cover them.
6. **S6 — `lmtr-list` SET grows one member per interpolated limiter name forever** (`base.rb:107-118`; spec blesses `"stripe-#{user_id}"` names, `sidekiq-ent.md:75`). Fix without changing the key's type visible semantics: on `Limits.list` (`web/enterprise.rb`), drop members whose `lmtr:<name>` meta hash is gone (batched `SREM` of dead names during pagination scan); plus stop re-`SADD`ing on every construction — only register when meta hash is first written. If maintainer approves a bolder fix, migrate to ZSET scored by last registration with on-write trim — **flag: key-type change is dashboard-visible to third parties; default to the SREM-sweep approach.**
7. Read-side: `Limits.list` currently `SMEMBERS` + sort whole set per request (`api_controller.rb:185-189`) — after the sweep this self-heals; add `SSCAN`-based pagination only if still needed (defer otherwise).

## Tests

- Unit: create batch, never finish → all `b-<bid>-*` keys report TTL > 0 immediately after first flush.
- Unit: N batch creations → `batches` ZSET bounded; old members trimmed by score.
- Unit: reopen-batch `#on` with same callback ×100 → single callbacks entry, single fire on success.
- Unit: crash injected between enqueue and dedup-set → callback fires on retry (no permanent loss).
- Unit: `Limits.list` after meta-hash expiry → dead name removed from `lmtr-list`.
- Parity: batch suite (`bin/rake test:parity`) — TTL additions must not break Sidekiq Pro batch semantics (keys still live ≥ linger windows).

## Done when

- No TTL-less batch sub-key reachable from any creation path.
- `batches`/`dead-batches`/`lmtr-list` bounded under sustained load test.
- Callback loss window closed; duplicate-callback direction documented in code comment.
