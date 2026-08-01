# 03 — Client outage buffer fork safety

> Part of [`overview.md`](overview.md). Depends on: none.

## Files to change

- `lib/wurk/client/buffered.rb:40-41, 115-130, 137-148, 176, 183, 269, 329-337` — fork hook, overflow, factory pin, drainer
- `lib/wurk/client.rb:282-287, 376-383` — partial-pipeline buffering, enqueued metric
- `lib/wurk/swarm/child_boot.rb:107` — call the new fork reset alongside `reset_redis_pools!`

## Steps

1. **S1 (high) — buffer + drainer are process-global and fork-unsafe.** `@buffer`, `@drainer`, `BUFFER_MUTEX`, `INSTALL_MUTEX` are class-level; no fork hook exists anywhere. Consequences: (a) parent buffers N payloads → forks → parent + W children each `drain!` → up to `(W+1)×N` duplicate jobs; (b) child inherits dead drainer thread (`running?` false, nothing restarts it) → up to `buffer_cap` job hashes pinned for process life; (c) fork while `BUFFER_MUTEX` held → child mutex locked with no owner → every `Client#push` deadlocks (`:317` calls `drain!` first).
   Fix: add `Buffered.reset_after_fork!` — clear `@buffer`, nil `@drainer`, recreate both mutexes; call from `ChildBoot#reconnect_after_fork` and from a `Process._fork` hook (Ruby 3.1+) so Puma/Unicorn preload forks are covered too. Make `Drainer#start` idempotent against a dead thread and re-arm from the fork event.
   Decision point: dropping the child's inherited copy means only the parent replays buffered jobs — correct (parent still owns them; duplicates are worse than the parent-only replay).
2. **S2 — `:raise` overflow silently drops the remainder.** `enbuffer` (`buffered.rb:115-130`) raises `Overflow, p` from inside the payloads loop → payloads after the raising one are neither enqueued nor buffered nor attached to the exception; `raise unless batched.empty?` (`:337`) is skipped. Fix: partition against remaining capacity before mutating; raise one `Overflow` carrying the entire undelivered slice; ensure the batched-payload re-raise still fires.
3. **S3 — replay duplicates on partial-pipeline failure.** `push_immediate` (`client.rb:282-287`) buffers ALL payloads when the pipeline raises, including queues whose `LPUSH` already applied. Fix direction: buffer per-queue-group (only groups whose command result is unknown/failed); document residual at-least-once duplication for the lost-reply case. Coordinate with 04 (pool retry) so the same payload can't be retried at both layers.
4. **S12 — `buffer_client_factory` pins one pool forever.** `buffered.rb:137-148`: first non-nil pool is captured; later `reset_redis_pools!` leaves the drainer replaying into a shut-down pool. Fix: resolve the pool at drain time (store a callable that reads current config / capsule pool), not at install time.
5. **S14 — `emit_enqueued` counts buffered jobs as enqueued.** `client.rb:376-383` runs after `raw_push` even when payloads only reached the buffer; `drain!` then counts them again as `jobs.recovered.push`. Fix: skip `emit_enqueued` for payloads that were buffered (return the buffered set from the rescue path, or emit inside the success branch only).

## Tests

- Fork test (real fork, real Redis): buffer 3 payloads under a stubbed outage → fork 2 children → restore Redis → assert each job enqueued exactly once, children's buffers empty, child `push` doesn't deadlock (bounded timeout).
- Unit: overflow `:raise` with a 1000-payload push at cap-1 → exception carries all undelivered payloads; none silently lost.
- Unit: drainer restart after simulated fork (kill thread, call reset, push) → drains.
- Commands: `bin/rake test`; enqueue + bulk-enqueue bench within 5%.

## Done when

- No duplicate enqueue across fork in the outage-replay test; no deadlock.
- Overflow path provably loses zero payloads.
- Metrics: buffered-then-drained job counted once as enqueued, once as recovered.
