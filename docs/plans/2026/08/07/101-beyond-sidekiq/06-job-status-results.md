# 06 — Job status, progress & results (`Wurk::Status`)

> Part of [`overview.md`](overview.md). Depends on: none. **Blocks 07** (`GET /jobs/:jid`) and **11** (chains need a result to pipe).
>
> **Additive invariant:** opt-in per worker class. A worker that doesn't opt in writes nothing, reads nothing, allocates nothing. Default path unchanged.

## Why

Four census gaps in one feature ([`00-census.md`](00-census.md)): succeeded jobs vanish entirely (Asynq retention, Hangfire's succeeded list), no per-job progress outside batches/iterables (BullMQ `updateProgress`), no lookup by jid (BullMQ `Job.fromId`), no stored return value (BullMQ `returnvalue`, Celery result backend, Oban Pro output recording). Also subsumes the `sidekiq-status` gem, which the ecosystem suite already tests against (`bin/rake test:ecosystem`) — **check its expectations first; don't collide with its key names.**

## Data model

New keys only, under a new prefix declared in `lib/wurk/keys.rb` (follow `:15-53`):

| Key | Type | Holds | TTL |
|---|---|---|---|
| `status:<jid>` | HASH | `state`, `queue`, `class`, `enqueued_at`, `started_at`, `finished_at`, `progress`, `total`, `message`, `result`, `error_class`, `error_message`, `attempt` | configurable, default ~30 min; longer on `complete` if retention is on |

`state`: `enqueued` → `running` → `complete` \| `failed` \| `interrupted` \| `retrying` \| `dead`.

**No existing key is read or written.** No score format, no queue list, no sorted set touched.

## Files to change

- new `lib/wurk/status.rb` (+ `lib/wurk/status/` if it grows), `lib/wurk/middleware/status.rb`, `lib/wurk/lua/status_*.lua`.
- `lib/wurk/keys.rb` — new prefix + TTL constant.
- `lib/wurk/worker.rb` — `wurk_options track: true` (and the `Sidekiq::Worker` alias path).
- `lib/wurk.rb` — register the server middleware, guarded by the opt-in.
- `lib/wurk/client.rb:71,84` — write the `enqueued` row **only** for tracked classes; must not add a round-trip to untracked enqueue (fold into the existing pipeline/Lua, don't append a command).
- `lib/wurk.rb` — `Sidekiq::Status` alias if and only if it doesn't clash with the gem.

## Steps

1. Read `docs/target/sidekiq-{free,pro,ent}.md` — confirm nothing upstream owns this surface. This is a **Wurk extra**, not parity; it must not shadow a Sidekiq name with different semantics.
2. Check the `sidekiq-status` ecosystem suite (`test/ecosystem/`) before choosing key names or a `Sidekiq::Status` alias. Coexistence beats collision.
3. `Wurk::Status` API: `.get(jid)`, `.delete(jid)`, and inside a job `status.at(50, 100, "halfway")`, `status.message(...)`. Progress writes are HSET+EXPIRE — one round-trip, and **rate-limited/coalesced** so a tight loop calling `at()` per row can't flood Redis. Document the coalescing.
4. Result capture: the server middleware records `perform`'s return value. Cap the serialized size hard (e.g. 8 KB) and truncate with a flag rather than storing blobs — a job returning an ActiveRecord relation must not fill Redis. JSON only (`CLAUDE.md`: never MessagePack).
5. Terminal states: reuse the exact rescue taxonomy from `lib/wurk/batch/server_middleware.rb:56` so `interrupted`/`skipped` are not `failed` — the same trap as slice 01.
6. Retention: `complete` rows get their own TTL knob. Off by default; `0` means "delete immediately on success" (today's behavior).
7. Encryption: if args are encrypted (`lib/wurk/encryption.rb`), the result is likely sensitive too. Either encrypt stored results with the same key or refuse to store them for encrypted workers — pick one, document it, don't leak plaintext results beside encrypted args.

## Tests

- Unit: full lifecycle per state; progress coalescing; result truncation at the cap; TTL set on every write.
- Unit: untracked worker → **zero** new Redis commands (assert via command count, the harness from `bench/command_count.rb`).
- Unit: interrupted job → `interrupted`, not `failed`.
- Integration: real fork, status readable from another process mid-run.
- Ecosystem: `bin/rake test:ecosystem` still green with `sidekiq-status` installed.
- Encryption: tracked + encrypted worker stores no plaintext result.
- `rake bench` with tracking off — within noise.
- Coverage ≥90/90.

## Done when

- `Wurk::Status.get(jid)` returns state, progress, timings, result, error for a tracked job.
- Untracked workers are provably unchanged (command count + bench).
- Completed-job retention is configurable, off by default.
- No collision with `sidekiq-status`; ecosystem suite green.
- Encrypted workers don't leak results.
