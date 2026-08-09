# Measurement: fetch under a configured cap (Slice 10, step 1)

**Date:** 2026-08-09 — settles step 1 of [`10-global-concurrency.md`](10-global-concurrency.md)
("Measure first... so the cost is known, not argued") before any gate or
`lib/` change is written.

## What this is not

`bench/fetch_capped.rb` (landed in #397, the foundations PR) is a **standalone
probe**, not a preview of the real feature. Slice 10 has not landed: no
fetcher gate, no config option, no `lib/wurk/lua/queue_slot.lua`. The probe
wraps the real `Wurk::Processor#process_one` path in a throwaway
acquire/release Lua pair, EVAL'd directly rather than folded into
`Fetcher::Reliable#lmove`'s existing pipeline (`lib/wurk/fetcher/reliable.rb:449-453`,
which already does the ack's `LREM`+`DEL` and the `LMOVE` in **one** pipelined
round trip). That's deliberate: it prices "two bare extra round trips around a
fetch" so design constraint #2 in the plan ("must join that pipeline or that
Lua, not add a round-trip") has a number to justify itself against, not an
assertion.

## Harness

`REDIS_URL=redis://localhost:16379/0 bundle exec ruby -Ilib bench/fetch_capped.rb`
(local Redis 7 in Docker, port-forwarded — sandbox has no `redis-server`
binary). `benchmark-ips`, 2s warmup / 5s measure, single-threaded so the cap
never actually binds (see script comment) — this reports the round-trip cost
of the gate, not its throttling behavior; that needs slice 10's own
multi-process integration test.

## Numbers

Three runs, same box, back to back:

| Run | uncapped (i/s, µs/i) | capped, prototype slot (i/s, µs/i) | slowdown |
|---|---|---|---|
| 1 | 2.936k, 340.6 µs | 1.114k, 897.5 µs | 2.64x |
| 2 | 2.773k, 360.6 µs | 1.182k, 845.9 µs | 2.35x |
| 3 | 2.911k, 343.5 µs | 1.286k, 777.6 µs | 2.26x |

±18–25% variance per run (Docker bridge network + shared sandbox host), but
the ratio holds across all three: **the prototype gate adds roughly
450–550 µs per fetch+execute, 2.2x–2.6x the uncapped cost.** For scale,
`bench/fetch_execute.rb` (the real gate script, no cap) reported 2.515k i/s /
397.6 µs stand-alone — consistent with `fetch_capped.rb`'s own uncapped side,
so the probe's baseline isn't an outlier.

`bench/command_count.rb` reconfirms the unconfigured floor this slice must not
move: **3.00 commands/job**, matching `BUDGET=BASELINE=3` and the number
published at `docs/benchmarks.md:81`. The prototype's *capped* path adds 2
more round trips (1 command each) on top of that 3 — 5 commands/job, 3 round
trips — when configured, which is the number a real fold-in must beat.

## Reading the number

The added cost is exactly two synchronous `EVALSHA` round trips bracketing a
fetch that already pays one pipelined round trip for ack+`LMOVE`
(`reliable.rb:449-453`). Two more round trips of the *same shape* as that
existing one roughly triples the round-trip count for the operation, and the
measured 2.2x–2.6x latency multiplier tracks that directly — this environment
is round-trip-latency-dominated (Docker bridge, not a unix socket), so the
ratio is the informative number, not the absolute µs.

This is exactly the failure mode design constraint #2 warns about: a cap
implemented as "acquire, then the existing fetch, then release" as three
separate round trips is not a cheap feature, it's roughly a 2.5x tax on every
capped fetch. It is not evidence against shipping global concurrency — it's
evidence that the acquire (and ideally the release) **must** ride inside the
existing pipeline or a single Lua script alongside the `LMOVE`, per constraint
#2, or the "cheap when configured" bar in the plan's opening paragraph is not
met.

## What this settles vs. what it doesn't

- Settles: the *shape* of the real implementation cannot be "bolt two round
  trips onto the outside of `lmove`" — that number is now measured and it's
  bad enough to fail review on its own.
- Does not settle: ship vs. defer. That call, per the plan's "Done when",
  needs the real slot model (step 2), fairness under contention (step 3), and
  the actual `rake bench` / `command_count` deltas once a real gate exists —
  not this prototype's numbers.
- Unconfigured-queue cost is unaffected either way: `command_count.rb` still
  reports 3.00, unchanged by this probe (the probe never touches the real
  fetcher).
