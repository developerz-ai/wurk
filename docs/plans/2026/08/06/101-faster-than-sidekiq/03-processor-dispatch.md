# 03 — Processor dispatch + middleware traverse

> Part of [`overview.md`](overview.md). Depends on: none (disjoint files from 02). Per-job Ruby cost.

## Files to change

- `lib/wurk/middleware/chain.rb` — cheaper per-job construction/traverse.
- `lib/wurk/processor.rb` — tid memo, clock, stats micro-costs.
- `lib/wurk/job_logger.rb`, `lib/wurk/context.rb` — single-hash context.
- `lib/wurk/component.rb` — thread priority (verify first).

## Constraints (already adjudicated — don't re-litigate)

- Middleware **instances stay per-job-fresh** (`chain.rb:10-12`, documented Sidekiq contract; caching rejected in prior plan).
- `Object.const_get` per job stays (`processor.rb:233`; memo breaks Rails reloading).
- The 4 mutex acquisitions in `stats` stay (prior plan: leave the mutexes alone).

## Steps

1. **P4 — chain mechanics.** `Entry#make_new` (`chain.rb:120-123`) does `respond_to?(:config=)` per instantiation → cache the capability on the Entry at `add` time. `invoke` (`chain.rb:86-99`) allocates a traverse lambda and `shift`s the array (O(n) memmove ×6) → index-recursive traverse over the frozen entries array, no lambda, no array mutation. Add Sidekiq's `return yield if empty?` short-circuit if missing (`sidekiq chain.rb:170`).
2. **Cheapen the no-op built-ins' early returns.** Five of six default server entries no-op for a plain job (map in 01). Make each early-return branch allocation-free (check the guard hash lookups don't build strings/arrays; e.g. `batch/server_middleware.rb:34-35`, `middleware/expiry.rb:35-36`, `metrics/statsd.rb:120-122`). Do **not** conditionally deregister built-ins in this slice — that's the escalation path in overview "Risks", needs its own sign-off.
3. **P7 — `stats` micro-costs** (`processor.rb:249-260`): memoize `tid` per thread (it's `Thread.current.object_id ^ Process.pid` — constant per thread; pid guard for fork safety); replace `Time.now.to_i` with `Process.clock_gettime(CLOCK_REALTIME, :second)`.
4. **P9 — single-hash job-log context.** `JobLogger#prepare` (`job_logger.rb:43-60`) builds a context hash + walks `logged_job_attributes`; `Context.with` (`context.rb:15-21`) merges twice. Build one hash, merge once; skip the attribute walk when none of `%w[bid tags]` present (common case).
5. **Frozen interrupt hashes.** Verify the two `Thread.handle_interrupt` calls (`processor.rb:175-177`) use frozen constant hashes, not per-job literals (Sidekiq: `processor.rb:161-164` there). Fix if literal.
6. **Thread priority.** Check `safe_thread`/`component.rb:40-42`: if processor threads don't set `priority = -1`, add it (Sidekiq `component.rb:19,44-48` — 50ms quanta, fewer stalls at high concurrency).
7. **Dispatch-onion audit (measure, then trim).** `processor.rb:211-228` nests 7 blocks pre-perform. Inline what's free: e.g. `Profiler.call` should be a guard-then-yield with zero allocation when `job["profile"]` absent; reloader default should be the identity proc. Only restructure where a stackprof of the noop bench shows frames >1% — don't refactor blind.

## Tests

- Existing: `test/unit/middleware_chain_test.rb`, `middleware_chain_ops_test.rb`, `middleware_builtins_test.rb`, `test/unit/*processor*`.
- New: chain traverse order + rescue-unwind semantics preserved (esp. prepend order, per-job-fresh instances still fresh — assert object identity differs across two invokes); tid stable per thread and changes across fork.
- `bin/rake bench:fetch_execute` and `bench:memory` per commit (memory bench = allocation rate; steps 1/3/4 should move it).
- `bin/rake test:parity` — chain semantics are Sidekiq surface.

## Done when

- Per-job allocations down measurably in `bench:memory` (jobs-per-1k-allocations up, no >5% regression elsewhere).
- Chain invoke does ≤1 allocation per entry (the instance itself) + zero for traversal.
- Parity + full suite green; coverage ≥90/90.
