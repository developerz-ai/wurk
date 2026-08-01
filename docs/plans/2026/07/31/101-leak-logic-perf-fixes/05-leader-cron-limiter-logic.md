# 05 — Leader, cron, limiter logic

> Part of [`overview.md`](overview.md). Depends on: none.

## Files to change

- `lib/wurk/leader.rb:92-99, 110-119` — atomic release, start race
- `lib/wurk/cron.rb:565-578, 640-655` — fire-mark CAS
- `lib/wurk/limiter/window.rb:21-33` — clock-skew trim
- `lib/wurk/limiter/bucket.rb:41` — boundary sleep
- `lib/wurk/limiter/concurrent.rb:18, 66, 107` — dead metrics

## Steps

1. **F3 — `Leader#release` GET-then-DEL can delete the new leader's lock** → up to 15 s dual-leader (double cron fire, double rollups). The Lua already exists: `Lua::RELEASE_IF_OWNER` (`lua.rb:294-299`, used by `Unique.release_if_owner`). Route release through `Lua::Loader.eval_cached(conn, :release_if_owner, keys: [@key], argv: [@owner])`.
2. **F12 — `Leader#start` spawns outside the mutex** (`leader.rb:110-119`) → double-start leaks a second leader loop. Move `@thread = spawn_loop_thread` inside `synchronize` — copy `Reaper#start` (`reaper.rb:83-91`).
3. **F4 — cron fire mark is HMGET→decide→enqueue→HSET, guarded only by a 5 s-stale `leader?` cache** (`component.rb:87-96`) → leadership handover double-fires periodic jobs. Fix: single Lua CAS on `loops:<lid>` — `if HGET nf <= now then HSET nf=<next>; return 1 else return 0`, enqueue only on 1. Keep hash field names/values byte-identical (dashboard reads them). Advance `nf` *before* enqueue; on enqueue failure next tick is naturally skipped-one — log it (spec `sidekiq-ent.md:510`: best-effort is acceptable, double-fire is not).
4. **F8 — `Window#size` trims with the client clock and mutates on read** (`window.rb:21-27`): skewed dashboard host evicts live entries → limit exceeded ~2×. Fix: read path uses `ZCOUNT` with no trim (compute cutoff for counting only), or a read-only Lua deriving time from `TIME` per the invariant in `limiter_bucket_acquire.lua`'s header. Trim stays exclusively in the acquire script.
5. **F9 — `Bucket` waits at 20 Hz, never sleeps to boundary** (`bucket.rb:41`): `0.05` is inside the `min`, so `secs_to_next` is dead. Fix: `sleep [[remaining, secs_to_next.to_f].min, 0.05].max`.
6. **F10 — `Concurrent` never writes `held`, never detects overages.** `bump_counter('held')` on successful acquire; `bump_counter('overages') if release(slot).to_i.zero?` — the release Lua's header (`limiter_concurrent_release.lua`) says the Ruby side must do exactly this.

## Tests

- Unit: release while another owner holds the key → key survives (CAS). Race test: expire-then-reacquire between GET and DEL is now impossible by construction — assert via Lua path being used.
- Unit: two concurrent cron pollers ticking the same loop id against real Redis → exactly one enqueue per due tick (thread pair, N iterations).
- Unit: `Window#status` with `Time.now` stubbed +30 s → ZSET cardinality unchanged after read; acquire still enforces limit.
- Unit: bucket exhaustion sleeps ≥ min(remaining, secs_to_next); assert via clock-time bounds not command counts.
- Unit: concurrent limiter held/overage counters increment in the documented scenarios.
- Commands: `bin/rake test`, `bin/rake test:parity` (limiter surface is Ent parity — spec §refs in `docs/target/sidekiq-ent.md`).

## Done when

- Dual-leader window closed on release; cron double-fire test green over repeated runs.
- Read-only limiter status is genuinely read-only; skew test passes.
- `held`/`overages` visible in `status`; no Redis key/field changes anywhere.
