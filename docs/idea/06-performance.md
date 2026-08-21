# Performance — How Wurk Is Measured

Speed is measured, not claimed. Wurk is **not** currently faster than stock Sidekiq: it runs at roughly 0.45×–0.86× depending on workload shape and process configuration, because reliable fetch and per-job metrics cost extra Redis round-trips. The numbers, the method, and the reproduction command live in `docs/benchmarks.md`.

The optimizations below are real and worth keeping — they are why the gap is not larger — but they have not added up to beating stock Sidekiq, and this document does not claim they have.

## Redis path

| Optimization | Rationale |
|---|---|
| BLMOVE instead of BRPOPLPUSH | Single atomic op, Redis 6.2+ |
| Lua bulk enqueue | N jobs in 1 roundtrip vs N MULTI/EXEC |
| Lua bulk fetch | Pop K jobs into private list in 1 op vs K BLMOVEs |
| Pipelined heartbeat | Heartbeat + stat counters in one pipeline |
| Per-fork connection pools | No cross-process socket contention |
| redis-client, not the legacy redis gem | Removes the redis-gem abstraction tax |
| EVALSHA caching | Scripts loaded once per pool, never re-uploaded |

## Process model

| Optimization | Rationale |
|---|---|
| Fork-based real parallelism | One GVL per child, not one shared across all threads |
| Copy-on-write Rails boot | Children share read-only memory with the parent |
| Specialized worker topology | Critical-queue forks don't fight bulk-queue forks |
| Embedded mode | One process tree — fewer context switches than Rails + separate Sidekiq daemon |

## Hot-loop micro-optimizations

| Optimization | Rationale |
|---|---|
| Frozen string literals everywhere | Less GC churn in the fetch + execute loop |
| Lazy job-args deserialization | JSON.parse only when middleware demands it |
| Middleware short-circuit | Jobs can opt out of the full chain when they don't need it |
| Pre-allocated context objects | Reuse the same buffer object across job runs in a thread |
| Concurrent::Promises for batch callbacks | Cheaper than thread-per-callback |

## Asset path

Precompiled dashboard assets ship inside the gem — see 09-precompiled-assets.md. No runtime asset compilation, no Sprockets reach for the SolidJS bundle. The dashboard loads as a static file from the gem's path.

## Things explicitly NOT done

- io_uring — interesting, not until benchmarks demand it.
- MessagePack job format — would break wire compat. Never.
- Custom Redis fork — never.

## Benchmark suite (required)

Every release must run, and must not regress on:

1. Enqueue throughput, single-client, single-queue.
2. Fetch + execute throughput, no-op perform.
3. Bulk enqueue throughput, 1000 jobs at a time.
4. Swarm boot time, Rails-app baseline.
5. Memory per worker post-boot, Rails-app baseline.

The benchmark job runs in CI wherever the `vars.WURK_BENCH_RUNNER` repository variable points (`ubuntu-latest` when unset). Results are published to the job summary and a sticky PR comment showing the delta vs main. Greater than 5% regression flags the PR.

## What actually gates a merge

`rake bench` is the regression gate: it compares Wurk against **its own past self** on enqueue, fetch+execute, bulk enqueue, swarm boot, and memory. A regression greater than 5% on any of those blocks the merge.

`rake bench:vs_sidekiq` is the comparison suite against stock Sidekiq. It gates nothing. A green CI run says nothing about how Wurk compares to Sidekiq — only that Wurk has not regressed by more than 5% against its own baseline on the measured metrics. A 4% regression still passes.

There is deliberately no "must beat Sidekiq to release" rule. One previously stood here and was not followed — v1.5.0 shipped on 2026-08-06 while slower — so it is removed rather than left as a policy releases ignore. Closing the gap is tracked as ordinary performance work, and `docs/benchmarks.md` is the place the current numbers are published.
