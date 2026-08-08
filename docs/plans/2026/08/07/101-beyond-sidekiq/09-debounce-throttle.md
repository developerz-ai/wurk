# 09 — Debounce & throttle-to-slot

> Part of [`overview.md`](overview.md). Depends on: none. Extends `Wurk::Unique` — read `lib/wurk/unique.rb` before starting.
>
> **Additive invariant:** new opt-in policies alongside the existing `until:` values. A worker using today's `unique:` behavior sees no change; a worker using neither sees no code path at all.

## Why

pg-boss's two collapse policies, absent from Sidekiq and from `Wurk::Unique`. Both solve problems Rails apps hit constantly — search-index rebuilds, webhook fan-in, cache warms, "user changed something, re-derive the projection".

| Policy | Behavior | Prior art |
|---|---|---|
| **debounce** | Collapse a burst; keep the **last** payload; fire after N seconds of quiet | pg-boss debounce, Inngest `debounce`, BullMQ dedup with TTL extension |
| **throttle-to-slot** | At most one per N-second slot; extras dropped (or coalesced) | pg-boss `singletonSeconds` |

Distinct from today's uniqueness: `Wurk::Unique` prevents a *duplicate* while one is pending/running. Debounce deliberately *delays* and *replaces*; throttle deliberately *drops*.

## What exists

`lib/wurk/unique.rb`:
- `DEFAULT_UNTIL = :success`, `VALID_UNTIL = %i[success start]` (`:49-50`).
- `lock_key(klass, queue, args)` (`:117`), `lock_key_for(job)` (`:125`), `unique_context(job)` (`:135`), `active_job_context` (`:165`), `release_if_owner(conn, key, jid)` (`:88`).
- Host hook `sidekiq_unique_context(job)` (documented `:36-44`) lets a class narrow the key — **this is already the "unique by arg subset" escape hatch**; document it rather than building a second mechanism.

## Files to change

- `lib/wurk/unique.rb` — new policy values; keep `VALID_UNTIL` validation strict so a typo fails loudly.
- new `lib/wurk/lua/debounce.lua`, `lib/wurk/lua/throttle_slot.lua`; register in `lib/wurk/lua.rb` (EVALSHA-cached once per pool — `CLAUDE.md`).
- `lib/wurk/client.rb:71,84` — the collapse decision happens at enqueue, on the client side.
- `lib/wurk/keys.rb` — new key prefixes for debounce/throttle state.
- `lib/wurk/worker.rb` — `wurk_options unique: { policy: :debounce, wait: 5 }` shape.

## Steps

1. **Debounce must be one atomic Lua call**, not read-then-write — two concurrent producers must not both schedule. The script: upsert the pending payload under the debounce key, (re)set the scheduled-set entry to `now + wait`, extend the key TTL. Replacing the payload means the *last* enqueue wins, which is the whole point.
2. Debounce writes into the existing `schedule` ZSET with the existing score format — **do not invent a parallel delayed structure**. A debounced job in `schedule` must be indistinguishable to any other reader, including stock Sidekiq and the dashboard.
3. Cap the delay: a key re-extended forever never fires. Add `max_wait` (fire regardless after this long from the *first* enqueue). Without it, a busy key starves — this is the classic debounce bug.
4. **Throttle-to-slot**: `SET key jid NX EX <slot>` semantics; on collision, drop. Decide and document whether the dropped enqueue returns `nil` (pg-boss returns no job id) or the winning jid — callers branch on this.
5. Both policies interact with `Wurk::Unique`'s existing lock. Define precedence explicitly: a class declares **one** policy. Reject a config that sets both, at class-definition time.
6. `push_bulk` (`client.rb:84`): decide whether policies apply per item. Recommend yes, but it turns the single Lua bulk call into a per-item decision — measure. If the cost is real, restrict policies to `push` and raise on bulk rather than silently ignoring them.
7. ActiveJob path: `active_job_context` (`unique.rb:165`) already unwraps the wrapper class. Policies must key off the *inner* job, same as uniqueness does.

## Tests

- Unit: 100 rapid enqueues in a burst → exactly one job, carrying the **last** payload.
- Unit: `max_wait` fires under continuous re-enqueue (the starvation case).
- Unit: throttle drops within slot, admits in the next slot; documented return value.
- Unit: policy + existing `unique:` both set → raises at class definition.
- Unit: debounced entry in `schedule` has the canonical score format and is readable by the plain `ScheduledSet` inspector.
- Concurrency: two processes debouncing the same key simultaneously → one job (integration, real Redis, real forks).
- ActiveJob wrapper keys off the inner class.
- Ecosystem: `sidekiq-unique-jobs` suite still green.
- `rake bench`: no policy configured → within noise; with debounce → report the added enqueue cost.

## Done when

- Debounce collapses a burst to one job with the last payload, and can't starve.
- Throttle admits at most one per slot with documented semantics.
- Debounced/throttled jobs are ordinary Sidekiq-shaped entries in existing structures.
- Conflicting config fails at definition, not at runtime.
- Existing `Wurk::Unique` behavior and the ecosystem suite unchanged.
