# 04 — Batch / limiter / scheduler logic bugs

> Part of [`overview.md`](overview.md). Depends on: none.

Root cause shared by three bugs: **any `bid`-carrying client push is treated as batch registration**. `BATCH_PUSH` unconditionally `HINCRBY total/pending` (`lib/wurk/lua.rb:81-85`), so retry promotion and scheduled promotion re-register live jids → `pending` inflates → `:success` never fires.

## Files to change

- `lib/wurk/lua.rb:81-85` — `BATCH_PUSH` else-branch: no already-registered guard.
- `lib/wurk/client.rb:270,310-321` — `bid` partition routes every push through `BATCH_PUSH`.
- `lib/wurk/scheduled.rb:61` — default `Enq#drain_set` re-pushes via `@client.push` (re-registers).
- `lib/wurk/job_retry.rb:180-186` — retry payload keeps `bid` (correct) but re-push re-registers.
- `lib/wurk/limiter/server_middleware.rb:44,57-74` — OverLimit reschedule returns nil → outer Batch acks success.
- `lib/wurk/batch/server_middleware.rb:49-56,94` + `lib/wurk.rb:266-269` — middleware order comment is wrong.
- `lib/wurk/lua.rb:47-57` — `RELIABLE_SCHEDULE_PROMOTE` no `enqueued_at` stamp.
- `lib/wurk/batch.rb:184-188` — empty-marker check vs scheduled-only `jobs` block.
- `lib/wurk/processor.rb:190-200` — `parse_or_kill` ZADD to dead without trim.

## Steps

1. **Idempotent batch registration.** In `BATCH_PUSH` Lua: make `SADD jids` the guard — `if redis.call("sadd", KEYS[2], ARGV[2]) == 1 then hincrby total/pending end`. A jid already in the live set is a re-push (retry/scheduled promotion), not a new job. Wire-compat: key names, field names, JSON untouched — only increment discipline changes. Verify against `docs/target/sidekiq-pro.md` §2 batch counter semantics before merging.
2. **Registration at creation, not at push** (belt to step 1's suspenders): scheduled jobs pushed inside `Batch#jobs` bypass `BATCH_PUSH` (routed to `push_scheduled`, `client.rb:248-260`) so `total` doesn't move → `batch.rb:184-188` empty-marker misfires and `:complete`/`:success` can fire while real jobs sit in `schedule`. Fix: register scheduled `bid` jobs into the batch at enqueue time (SADD jid + HINCRBY under the same guard — a `BATCH_SCHEDULE` variant of the Lua that ZADDs and registers atomically). Then step 1's guard makes later promotion a pure LPUSH-equivalent.
3. **Promotion paths.** After steps 1–2 both scheduler paths converge: default `Enq` re-push is now harmless (guard blocks re-registration); `ReliableEnq` never registered anyway. Confirm retry re-push (`job_retry.rb:180-186` → ZADD `retry` → promotion) also lands in the guard path.
4. **Limiter × Batch ordering.** Chain is outermost-first (`middleware/chain.rb:86-99`); Batch is OUTER, Limiter INNER — a rescheduled OverLimit returns nil and outer Batch `ack_success`es a job that hasn't run (premature `:success`). Fix the mechanism, not the order: `Limiter::ServerMiddleware` on reschedule should raise/propagate a control signal the Batch middleware recognizes as not-success — simplest spec-faithful fix: re-raise `OverLimit` after rescheduling and have `Processor` treat it as handled-no-retry (Sidekiq Ent semantics), so Batch's rescue path (`batch/server_middleware.rb:54-56` `ack_failed`? no —) — careful: it must be *neither* success nor failure. Introduce `Wurk::Limiter::Rescheduled` exception; Batch middleware rescues it, skips both acks, re-raises; Processor rescues it, acks the UoW (job re-enqueued already), no retry record. Fix the wrong comment at `wurk.rb:266-267`.
5. **`enqueued_at` on reliable promotion.** `RELIABLE_SCHEDULE_PROMOTE` (`lua.rb:47-57`) LPUSHes stored payload verbatim — no `enqueued_at` (scheduled origin) or stale (retry origin). Stamp it in Lua: `cjson.decode/encode` cost vs wire-parity — spec requires restamp (`docs/target/sidekiq-free.md:191-192`, client parity at `client.rb:298`). Pass `now_ms` as ARGV; decode, set `enqueued_at`, encode. Benchmark: promotion is not the hot path; acceptable.
6. **Ent limiter reschedule cap** (`limiter/server_middleware.rb:44` routes to dead set; Ent spec §1.4 says re-raise into retry pipeline): keep Wurk behavior, record divergence — handled in 07. No code change here.
7. **Dead-set trim.** `parse_or_kill` (`processor.rb:190-200`): after ZADD, apply the same trim as `send_to_morgue` (`job_retry.rb:263-269`) — extract a shared `DeadSet#kill_raw`/trim call; also fixes the off-by-one at `dead_set.rb:41` (`-(max_jobs + 1)` → `-max_jobs`, spec `sidekiq-free.md:1579`).
8. **Scheduler drain resilience.** `Enq#drain_set` (`scheduled.rb:58-62`): a raising `@client.push` aborts the remaining due jobs until next poll — rescue per-job, log, continue the loop (the popped job is still lost in the default scheduler — documented tradeoff; `reliable_scheduler!` is the fix, don't re-engineer here).

## Tests

- Batch retry round-trip (integration): batch of 2, one job fails once then succeeds → `:success` fires, `total==2`, `pending==0`. This is the headline regression test.
- Scheduled-in-batch: `perform_in` inside `batch.jobs` → no premature `:complete`; fires after promotion+run.
- Limiter reschedule inside batch → no ack, `:success` only after the job actually runs.
- Reliable promotion stamps fresh `enqueued_at` (compare against `client.rb:298` path).
- Lua unit tests for the SADD-guard (idempotent double-push).
- Parity: `bin/rake test:parity` — batch + scheduler oracles must stay green.

## Done when

- A batch containing any retried/scheduled/rate-limited job completes with correct counters and fires `:success` exactly once.
- Both schedulers emit wire-identical promoted payloads.
- Dead set bounded on the malformed-JSON path.
