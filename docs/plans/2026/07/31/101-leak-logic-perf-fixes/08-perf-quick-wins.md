# 08 — Perf quick wins (behavior-preserving only)

> Part of [`overview.md`](overview.md). Depends on: run after 02 and 07 (shared files: `fetcher/reliable.rb`, `metrics/history.rb`). Every item below is risk-none/low per the perf audit; the deferred list at bottom is NOT in scope without maintainer sign-off. Wire compat: no key, JSON, or score changes anywhere here.

## Files to change

- `lib/wurk/client.rb:376-383` — statsd guard (P5)
- `lib/wurk/metrics/history.rb:72-113` — time-key + field memos (P2a)
- `lib/wurk/fetcher/reliable.rb:58-61, 105-110, 44-47` — hostname/private-name/queue-key memos (P3, P8)
- `lib/wurk/processor.rb:243-253` — tid memo, clock_gettime (P7)
- `lib/wurk/middleware/chain.rb:75-125` — `config=` capability cache, lambda-free traverse (P4)
- `lib/wurk/context.rb:15-21` — single-hash path (P9)
- `app/controllers/wurk/api/serializers.rb:17-31` — stats payload de-dup (P10)
- `lib/wurk/swarm.rb` boot + `lib/wurk/swarm/child_boot.rb:121-126` — pre-fork Lua load (P11)
- `lib/wurk/scheduled.rb:24-26` — stale comment only (from P12's finding; the batching itself is deferred)

## Steps

1. **P5 (cheapest win) — `emit_enqueued` allocates tags per payload even with no statsd client.** Add `return unless Wurk::Metrics::Statsd.client` at top. ×1000 on bulk enqueue. Risk: none (loop is a no-op when nil).
2. **P2a — History middleware per-job Time/strftime garbage.** Memoize `[epoch_minute, minute_string]` / `[epoch_hour, hour_suffix]` class-level; memo `{klass => [p_field, f_field, ms_field]}`. Byte-identical keys; lost thread race recomputes identical string. Risk: none.
3. **P3 — `Socket.gethostname` ≥2×/job.** Memoize host (`@host ||= ENV['DYNO'] || Socket.gethostname`); memoize full private-list name per queue **with pid guard** (`@cached_pid != Process.pid → reset`) — pid guard is load-bearing (parent may touch pre-fork; a child acking into the parent's list would be a real bug). Coordinate with 02's key-shape change (nonce) — memoize the *new* shape.
4. **P8 — fetch-loop rebuilds `queue:<name>` strings every pass.** Lazy frozen `{name => "queue:name"}` memo built on first use post-`prepare!` (queue list mutates during `ChildBoot#apply_slot_to_config` — never build at class load). Reverse memo for `UnitOfWork#queue_name`.
5. **P7 — Processor stats micro:** per-instance `@tid ||= tid` (do NOT reuse the logger's thread-local — stale pid after fork corrupts `<identity>:work`); `::Process.clock_gettime(CLOCK_REALTIME, :second)` instead of `Time.now.to_i`. Leave the mutex counters alone (audit verdict: not worth GVL-dependent tricks).
6. **P4 — middleware `respond_to?(:config=)` per job.** Cache capability on `Entry` at construction (`method_defined?` check). Optional: index-recursive traverse to drop the per-job lambda. Do NOT cache middleware instances (per-job-fresh is the documented Sidekiq contract, `chain.rb:10-12`).
7. **P9 — `Context.with` two hashes where one suffices:** `prior ? prior.merge(hash) : hash.dup` — keep the `dup` (callers' hashes must not alias into `Context.add` mutation).
8. **P10 — SSE stats payload 9 RTTs → ≤6 (serializer-local).** Call `queue_summaries` once; derive `enqueued = summaries.sum(&:size)` and `latency` from the `default` summary. Keep `Stats` public API untouched for third parties. Optional second step to 2 RTTs via aggregated pipelines — same output, more consistency.
9. **P11 — every swarm child re-uploads 14 Lua scripts on the boot-critical path.** `SCRIPT LOAD` is server-side global: load once in `Swarm#boot` pre-fork (before `close_parent_sockets`); child keeps only PING. Keep the `NOSCRIPT` rescue paths as safety net (they already exist: `loader.rb`, `client.rb:296-314`, `reliable.rb:129-144`). Zero-risk fallback if reviewers balk: move child-side load after `fire_event(:startup)`, off the measured window.
10. **P13 — `Statsd.client` re-resolves when unconfigured:** after P5 the hottest caller is gone; apply the tri-state memo only if profiling still shows it, and gate it on `reset!`.
11. Fix stale comment `scheduled.rb:24-26` (claims single-checkout loop; implementation is per-job checkout by design).

## Deferred — do NOT implement without explicit sign-off (each changes observable behavior or risk profile)

- **P1a** Lua-folded fetch (paused check + LMOVE walk in one script) — biggest fetch win; needs new script + mid-pass pause-skip test. P1b (cache paused set per poll interval) is behavior-visible (late pause).
- **P2b** in-process history aggregation w/ periodic flush — dashboard lag + kill-9 loss window.
- **P6** single `verify_json` — changes strict-args behavior for halting middleware; needs the bulk-side compensation described in the audit.
- **P12** batched scheduler promotion — widens documented pop→push loss window from 1 to K.
- Middleware instance caching, lock-free counters, `build_instance` constant memo (breaks Rails reloading) — rejected outright.

## Tests

- Existing suites must stay green unchanged — these are refactors, not behavior changes; add unit tests only for the pid-guard memo (fork → child writes its own private list name) and the Entry capability cache (middleware gaining `config=` after chain build is the documented non-goal).
- Commands: `bin/rake test`, `bin/rake test:parity`, **`bin/rake bench` before/after per item** — commit granularity one item per commit so the benchmark bot attributes deltas.

## Done when

- enqueue / bulk-enqueue / fetch+execute / swarm-boot / memory benches all ≤ baseline, with measurable improvement on at least enqueue (P5), fetch+execute (P2a/P3/P8), swarm boot (P11).
- No new Redis commands, keys, or JSON changes; parity green.
