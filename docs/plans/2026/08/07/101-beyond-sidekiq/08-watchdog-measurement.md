# Measurement: one watchdog vs N timer threads (Slice 08)

**Decision:** one `Wurk::Watchdog` per Capsule (so one per Manager), spawned by
the first bounded job. Not stdlib `Timeout`, not a timer thread per job.
**Date:** 2026-08-08 — settles step 1 of [`08-timeout-deadline.md`](08-timeout-deadline.md).

## Correcting the premise

The plan says stdlib `Timeout` "spawns a thread per call". That was true up to
timeout 0.1.x (Ruby ≤ 3.0). Since timeout 0.2 / Ruby 3.1 it runs **one** shared
monitor thread and pushes each call onto its request queue — measured here on
Ruby 3.2.3 with the bundled timeout 0.6.1, one `Timeout stdlib thread` for any
number of concurrent calls. So thread count is *not* what separates the options.

What does:

- **Containment.** `Timeout::Request#interrupt` calls `Thread#raise` under a
  `@done` mutex and nothing else. A bound that wins the race against the block
  returning is therefore delivered at whatever checkpoint the target thread
  reaches next — in a Processor that is the ACK, or the next job's `perform`.
  The gem's own documentation instructs every caller to wrap each call in a
  `Thread.handle_interrupt(klass => :never)` / `:immediate` sandwich to avoid it.
  `Watchdog#watch` writes that sandwich once, so every bounded job gets it, and
  a fired raise is delivered while `#watch` is still on the stack.
- **A bound that already passed.** `Timeout.timeout` raises `ArgumentError` on a
  negative `sec`. An absolute `deadline` read off an old payload yields exactly
  that, so every call site would need its own guard.

## Numbers

`bundle exec ruby` on Ruby 3.2.3 (timeout 0.6.1), trivial guarded block, warm.
Per-call cost of arming and retracting a bound that never fires — the cost every
bounded job pays:

| Shape | N=200k | per call | vs watchdog | allocations/call |
|---|---|---|---|---|
| unbounded (baseline) | 0.016 s | 0.08 µs | — | 0 |
| `Watchdog#watch` | 0.60 s | 3.0 µs | 1.0x | 7 |
| `Timeout.timeout(sec, klass)` | 0.89 s | 4.5 µs | 1.5x | 7 |
| `Timeout.timeout(sec)` (default class) | 1.13 s | 5.7 µs | 1.9x | 7 |

The shape the plan asked to price against — one timer thread per bounded job,
killed and joined on completion — at N=20k:

| Shape | per call | vs watchdog |
|---|---|---|
| `Watchdog#watch` | 2.8 µs | 1.0x |
| `Timeout.timeout(sec, klass)` | 4.0 µs | 1.4x |
| `Thread.new { sleep sec; target.raise }` per job | 27.4 µs | 9.6x |

Idle cost of the scanner with nothing armed, `SCAN_INTERVAL = 0.5`:
**0.0011 s CPU over 3 s wall = 0.036%** of one core. That is the price of the
coarse-scan design, and it buys back the signal-per-arm a
wake-at-nearest-deadline loop would need. Overshoot is bounded by the interval:
a bound fires in `[deadline, deadline + 0.5s)`.

And unconfigured — no job declaring `timeout:`/`deadline:` — the cost is zero by
construction, not by measurement: `Capsule#prepare!` allocates the object, the
first `#watch` spawns the thread, and nothing calls `#watch`. Pinned by
`WatchdogTest#test_construction_spawns_no_thread`.

## Harness

Not committed as a bench script: it prices an alternative we are not shipping,
and `rake bench` gates wurk against its own past self. Reproduce with

```ruby
# bundle exec ruby -Ilib
wd = Wurk::Watchdog.new(Wurk::Capsule.new('m', Wurk::Configuration.new))
Benchmark.bm { |b| b.report('watch') { N.times { wd.watch(60, Bound) { nil } } } }
```

plus the same loop over `Timeout.timeout(60, Bound)` and over a per-call
`Thread.new { sleep 60; target.raise(Bound) }` that is killed and joined in an
`ensure`.
