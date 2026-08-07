# 04 — Enqueue, bulk, batch

> Part of [`overview.md`](overview.md). Depends on: none (disjoint files). Moves `rake bench` enqueue/bulk metrics, not the vs_sidekiq ratio (driver bypasses the client — `bench/vs_sidekiq.rb:117-128`).

## Files to change

- `lib/wurk/client.rb` — double verify, statsd emit, batch pipelining, group_by fast path.
- `lib/wurk/job_util.rb` — merge diet, clock, verify dispatch table.
- `lib/wurk/metrics/statsd.rb` — client resolution memo.

## Steps

1. **P6 — single `verify_json`.** Runs at `client.rb:143` (inside chain) **and** `:62` (on the returned payload) — full recursive args walk twice, default mode `:raise` so never skipped. Match Sidekiq exactly: verify once, after client middleware (`sidekiq client.rb:101` order: normalize → middleware → verify → raw_push). Keep re-verify only if middleware mutated args — Sidekiq doesn't, so neither do we.
2. **Verify-walk dispatch table.** If `verify_json`'s recursion is a `case`/`is_a?` ladder, port Sidekiq's identity-keyed lambda table (`job_util.rb:80-111` there): `compare_by_identity` hash on `val.class`, default identity lambda — one lookup + call per node, zero allocation.
3. **P5 + P13 — statsd emit guard.** `emit_enqueued` (`client.rb:439-447`) builds 2 tag strings + an Array per payload with no client configured; `Statsd.client` re-resolves config every call (`metrics/statsd.rb:94-101`). Tri-state memo (`:unset/nil/client`) reset on config change + fork; `emit_enqueued` returns before any allocation when nil. ×1000 on every bulk push.
4. **Merge diet in `normalize_item`** (`job_util.rb:50-56`, `:95-98`): collapse to one `defaults.merge(item)` where possible; `wrap_options` merges only when wrapping actually applies. Compare against Sidekiq `job_util.rb:43-63` (one merge, empty `TRANSIENT_ATTRIBUTES` loop).
5. **Clock.** Replace any `Time.now`-based `created_at`/`enqueued_at` stamping with `Process.clock_gettime(CLOCK_REALTIME, :millisecond)` **only if the serialized value stays byte-format-identical** to what wurk emits today (wire-compat: job JSON field format is sacred — check `docs/target/sidekiq-free.md` for the stamp format first). Stamp once per batch, not per job (Sidekiq `client.rb:288`).
6. **Batch (`bid`) enqueue pipelining.** `client.rb:379-391` does one EVALSHA RTT per job, documented "not the hot path". Cheap, compat-safe: pipeline the EVALSHAs in slices (e.g. 100) — same script, same keys, same order; N RTT → N/100. Keep if the script depends on its own reply (verify it doesn't).
7. **Single-queue push fast path.** `raw_push` `group_by { j['queue'] }` (`client.rb:358-370`) allocates a Hash for the 1-job/1-queue common case — short-circuit when all items share a queue (or size==1).

## Tests

- Existing: `test/unit/client_test.rb`, `client_push_test.rb`, `client_buffered*.rb`, batch tests.
- New: verify_json runs exactly once per push (spy/counter); complex-args rejection still raises identically (mode `:warn`/`:raise` matrix); batch pipelined path produces identical Redis state vs per-job path (assert key dumps equal on real Redis); statsd memo resets on fork + reconfigure.
- `bin/rake bench:enqueue` + `bench:bulk_enqueue` per commit; `bin/rake test:parity` (push semantics are Sidekiq surface).

## Done when

- enqueue + bulk_enqueue `rake bench` metrics improve with no regression elsewhere; gate green.
- One verify walk, zero statsd allocations when unconfigured, ≤1 hash merge per normalized job.
- Parity + full suite green; coverage ≥90/90.
