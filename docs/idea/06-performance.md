# Performance — How Wurk Is Measured

Speed is measured, not claimed. The latest published paired comparison, measured 2026-08-07, put Wurk at roughly **0.87×–1.02×** of stock Sidekiq depending on workload and topology: parity on CPU and I/O, behind on noop and boot. This is dated evidence, not a current-release guarantee. The six paired medians, spread, environment and reproduction commands live in [docs/benchmarks.md](../benchmarks.md).

Metrics now accumulate in memory and flush periodically to Redis, rather than writing per job. ACK commands ride the next fetch's pipeline: the measured busy uncapped path costs 3 Redis commands in one round trip, versus stock Sidekiq's single BRPOP. Reliability still costs commands; batching does not mean zero overhead. A hard kill can lose unflushed metrics and re-run an already-finished job awaiting ACK.

## Redis path

| Mechanism | Scope and tradeoff |
|---|---|
| Reliable LMOVE / BLMOVE | Atomic move to a private list; blocking BLMOVE is the empty-queue fallback, not the busy-path command |
| Lua bulk enqueue | Batches enqueue work; no claim of a measured speedup for every payload size |
| Multi-queue Lua claim | Claims one job across remaining queues; not a K-job bulk fetch |
| Pipelined heartbeat | Publishes process state and buffered counters together |
| Per-fork connection pools | Fresh child sockets; parent connections must not survive fork |
| redis-client | The Redis client used by Wurk; not a standalone throughput result |
| EVALSHA caching | Uses cached scripts, reloading after a Redis script-cache miss |

## Process model

| Mechanism | Scope and tradeoff |
|---|---|
| Fork-based parallelism | One GVL per child on MRI |
| Copy-on-write boot | Children initially share parent memory; writes can make pages private |
| Specialized worker topology | Separates queue/thread assignments by fork role; no universal speedup claimed |
| Embedded mode | Deployment option, not evidence of fewer context switches or higher throughput |

## Hot-loop work

| Mechanism | Shipped behavior |
|---|---|
| Frozen string literals | Avoids mutable literal allocations |
| Parse once, carry raw JSON | Processor parses before execution and retains the raw payload for retry/stats paths |
| Cached logger attribute list | JobLogger caches configuration, but creates a fresh context hash per job |
| Queued batch callbacks | Ordinary jobs on the callback queue, not Concurrent::Promises or thread-per-callback |
| Lazy argument parsing (unshipped proposal) | Processor still parses before execution; compatibility review and measurement required |
| Per-job middleware opt-out (unshipped proposal) | The configured server middleware chain still runs |
| Reusable per-job contexts (unshipped proposal) | JobLogger still creates a fresh context hash per job |

The three unshipped proposals above are **not shipped optimizations**; they require compatibility review and measurement.

## Asset path

Precompiled dashboard assets ship inside the gem — see [09-precompiled-assets.md](09-precompiled-assets.md). Consumers do not compile the SolidJS bundle at runtime.

## Things explicitly NOT done

- io_uring — not justified by published measurements.
- MessagePack job format — would break wire compatibility. Never.
- Custom Redis fork — never.

## Benchmark suites and advisory policy

`bin/rake bench` runs the regression harnesses, including enqueue, fetch+execute, bulk enqueue, swarm boot, memory/allocation and CommandBuilder checks. It compares Wurk against **its own past self**, not stock Sidekiq. The CI job runs when benchmark inputs change, not for each release. Results appear in the job summary and sticky PR comment. A slowdown beyond both runs' error bounds plus `BENCH_REGRESSION_PCT` (default 5%) is flagged; the job is advisory, not a required merge check. A green run is not proof of no regression, nor evidence about Sidekiq.

`bin/rake bench:vs_sidekiq` is the separate comparison against stock Sidekiq; `WURK_BENCH_VS_PROCESSES=4 bin/rake bench:vs_sidekiq` compares four processes per side. `bin/rake bench:command_count` counts Redis commands. These tasks need local Redis. See [the benchmark guide](../benchmarks.md#running-it) for environment controls and isolation of the stock Sidekiq bundle.

There is no "must beat Sidekiq to release" rule. Closing the gap is ordinary performance work. Published historical results stay dated until another paired comparison is recorded; no benchmark was rerun for this prose correction.
