# 04 — RedisPool retry idempotency policy

> Part of [`overview.md`](overview.md). Depends on: none (coordinate with 03 step 3).

## Files to change

- `lib/wurk/redis_pool.rb:162-193` — retry classification
- Callers to audit/opt: `lib/wurk/client.rb:234`, `lib/wurk/scheduled.rb:60`, `lib/wurk/launcher.rb:179-185`, `lib/wurk/heartbeat.rb:100`, `lib/wurk/middleware/poison_pill.rb:127-134`

## Steps

1. **F5 — `#run` replays the whole caller block on any `RedisClient::ConnectionError`**, including `ReadTimeout`/`WriteTimeout` where the command may have applied server-side. Confirmed non-idempotent callers:

   | Caller | Effect of post-apply replay |
   |---|---|
   | `client.rb:234` `atomic_push` | duplicate job for a single `perform_async` |
   | `scheduled.rb:60` `zpopbyscore` | popped member discarded → **scheduled job lost** |
   | `launcher.rb:179-185` `write_stats` | double-counted `stat:processed/failed` |
   | `heartbeat.rb:100` `pipelined_beat` | LPOPped dashboard signals (TERM/TSTP) dropped |
   | `poison_pill.rb:127-134` `bump_counter` | over-count → premature kill to dead set |

2. Split the policy in `RedisPool#with`/`run`:
   - Always retryable: errors raised before the command was written — `CannotConnectError`, connect-phase timeouts.
   - Not retryable by default: `ReadTimeoutError` / post-write `ConnectionError` — raise to caller.
   - Opt-in: `pool.with(idempotent: true) { ... }` keeps today's replay for genuinely idempotent blocks (reads, EVALSHA-idempotent scripts, SET NX with owner CAS, EXPIRE).
3. Sweep every `pool.with` / `Wurk.redis` caller in `lib/` and tag the idempotent ones (fetch `LMOVE` is safe — reclaim covers it; `SMEMBERS`/`HGETALL`/LLEN reads are safe; the five above are not). Keep the sweep mechanical — one commit per subsystem for reviewability.
4. `zpopbyscore` (`scheduled.rb:60`): pop is unsafe to replay, but losing the popped value is worse — after the fix a ReadTimeout surfaces to `drain_set`, which must treat the pop result as unknown; acceptable because the default scheduler's documented loss window (`scheduled.rb:66-72`) already covers crash-between-pop-and-push, and `reliable_scheduler!` exists for loss-free. State this in the code comment.
5. `pipelined_beat`: signals must never ride a replayable block — either mark non-idempotent (retry loses at most one beat, next beat in 10 s) or split signal LPOPs from the beat writes.
6. Update the `redis_pool.rb` docstring ("at-least-once tolerates the rare duplicate") to describe the new split policy.

## Tests

- Unit with a fault-injecting connection wrapper (real Redis behind it — no Redis mocks in integration/parity, this is unit-level socket faulting): ReadTimeout after write → `atomic_push` raises, no duplicate LPUSH on retry-capable path; `CannotConnect` before write → retried and succeeds.
- Unit: `idempotent: true` block replays as before.
- Regression: heartbeat retry does not drop a seeded `<identity>-signals` entry.
- Commands: `bin/rake test`, `bin/rake test:parity`; fetch+execute + enqueue bench within 5%.

## Done when

- The five listed callers cannot duplicate/lose on injected timeout faults.
- Retry behavior for connect-phase failures unchanged (resilience from prior plan preserved).
- Docstring matches implementation.
