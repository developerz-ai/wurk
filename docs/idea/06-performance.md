# Performance — Why Wurk Is Faster

Speed is a pillar, not a side effect. Wurk must beat stock Sidekiq on every benchmark we ship.

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

Precompiled dashboard assets ship inside the gem — see 09-precompiled-assets.md. No runtime asset compilation, no Sprockets reach for the React bundle. The dashboard loads as a static file from the gem's path.

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

The benchmark job runs in CI on Blacksmith. Results uploaded as artifacts. PR comment shows delta vs main. Greater than 5% regression flags the PR.

## Promise

Wurk is at least as fast as stock Sidekiq on every benchmark, and ideally meaningfully faster on enqueue and bulk paths. If a release can't claim this, the release waits.
