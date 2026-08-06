# Benchmarks

Wurk is **not** currently faster than stock Sidekiq. Measured, published, and tracked here rather than claimed.

Two different benchmark suites live in `bench/`. They answer different questions and only one of them compares against Sidekiq.

| Suite | Question | Command | Gates merges |
|---|---|---|---|
| `bench/*.rb` | Did *this PR* slow wurk down vs `main`? | `rake bench` | Yes — >5% regression blocks |
| `bench/vs_sidekiq.rb` | Is wurk faster than *stock Sidekiq*? | `rake bench:vs_sidekiq` | No |

The regression gate can be fully green while wurk is slower than Sidekiq. It measures wurk against its own past self. Do not read `rake bench` as a competitive result.

## Throughput vs stock Sidekiq

wurk 1.4.0 · sidekiq 8.1.6 · ruby 3.4.9 (x86_64-linux) · 6 cores · local Redis · median of 3 runs × 4000 jobs.

Ratios below 1.00 mean wurk is slower.

**1 process × 5 threads**

| Workload | Sidekiq | Wurk | Ratio |
|---|---|---|---|
| noop | 1579 jobs/s | 714 jobs/s | 0.45× |
| cpu | 171 jobs/s | 138 jobs/s | 0.81× |
| io | 731 jobs/s | 538 jobs/s | 0.74× |

**4 processes × 5 threads** — `wurkswarm` (4 forks) vs 4 independent `sidekiq` processes

| Workload | Sidekiq | Wurk | Ratio |
|---|---|---|---|
| noop | 4240 jobs/s | 2061 jobs/s | 0.49× |
| cpu | 494 jobs/s | 424 jobs/s | 0.86× |
| io | 2709 jobs/s | 1791 jobs/s | 0.66× |

Boot to first job: sidekiq ~0.67s, wurk ~0.97s.

Forking does not close the gap. A stock Sidekiq user reaches multi-core by running N processes — that is the second table. The swarm's advantage is copy-on-write memory and a single supervisor, not throughput.

## Workload shapes

"Faster" is meaningless without naming the work. Three shapes, all in `bench/vs_sidekiq/job.rb`:

| Shape | Body | Measures |
|---|---|---|
| `noop` | empty `perform` | pure framework overhead — fetch, middleware, dispatch, ack |
| `cpu` | fixed arithmetic loop | holds the GVL; the shape fork-based parallelism exists for |
| `io` | `sleep` | releases the GVL; threads and forks both scale — the honest control |

`cpu` is the noisiest shape (±24–33% run to run). Single runs of it mean nothing; one isolated run read 1.17× before the median settled at 0.81×.

## Why wurk is slower

Redis commands per job, counted with `INFO commandstats` over 500 jobs. Reproduce with `bin/rake bench:command_count`, which prints the breakdown below and is the source these numbers are published from:

| Engine | Per job | Breakdown |
|---|---|---|
| Sidekiq | ~1 | 1 BRPOP. Stat counters buffered in memory, flushed on a timer. |
| Wurk | ~9 | 3 fetch + ack (LMOVE, then a pipelined LREM + DEL) · 6 metrics (4 HINCRBY + 2 EXPIRE) |

Two costs, opposite verdicts:

- **Reliable fetch** — 2 round-trips vs BRPOP's 1. This is [`Wurk::Fetcher::Reliable`](reliability.md), the default. Sidekiq's equivalent (`super_fetch`) is a paid Pro feature; stock Sidekiq's BRPOP loses in-flight jobs when a worker is killed. The extra round-trip buys a guarantee, and is not a defect.
- **Unbatched metrics** — 6 of the 9. `Wurk::Metrics::History` writes 2 HINCRBY + EXPIRE per job, twice over. Sidekiq buffers identical counters in memory and flushes on an interval. This is the actual gap.

The paused SET used to add a seventh, an `SMEMBERS` on every fetch pass; it is now read at most once per [`PAUSED_TTL`](reliability.md#fetch-order-and-polling) per fetcher and rounds to nothing per job.

## Running it

```bash
bin/rake bench:vs_sidekiq                            # 1 proc × 5 threads
WURK_BENCH_VS_PROCESSES=4 bin/rake bench:vs_sidekiq  # swarm vs 4 sidekiq procs
```

Needs a local Redis. First run installs `bench/vs_sidekiq/Gemfile` (stock Sidekiq, isolated bundle).

| Env var | Default | Meaning |
|---|---|---|
| `WURK_BENCH_VS_JOBS` | `5000` | jobs enqueued per run |
| `WURK_BENCH_VS_CONCURRENCY` | `5` | threads per worker process |
| `WURK_BENCH_VS_PROCESSES` | `1` | worker processes per side |
| `WURK_BENCH_VS_RUNS` | `3` | runs per (shape, engine); median reported |
| `WURK_BENCH_VS_SHAPES` | `noop,cpu,io` | subset of shapes to run |
| `WURK_BENCH_VS_CPU_ITERS` | `20000` | arithmetic iterations in the `cpu` shape |
| `WURK_BENCH_VS_IO_SECONDS` | `0.005` | sleep duration in the `io` shape |
| `WURK_BENCH_VS_VERBOSE` | unset | stream worker output instead of logging to `tmp/` |
| `WURK_BENCH_DB` | `12` | Redis logical DB (never 0 — the bench FLUSHDBs) |

## Fairness

The comparison is only worth reading if the control is real. What the harness guarantees:

- **Stock Sidekiq is actually stock.** Wurk ships `lib/sidekiq.rb` (the drop-in require shim) and Bundler puts every bundled gem's `lib/` on `$LOAD_PATH` — so inside the repo bundle, `bundle exec sidekiq` boots **wurk**. The Sidekiq side therefore runs from `bench/vs_sidekiq/Gemfile` with `RUBYOPT` and `RUBYLIB` cleared. The two distinct versions printed in the header are the proof; identical versions mean the run is void.
- **Identical job code.** `include Sidekiq::Job` resolves to wurk's compat module on one side and the real gem on the other. Same file, both sides.
- **Identical payloads.** Jobs are hand-built into the shared Redis key schema and pushed by the driver, so neither side's client library is on the clock.
- **Boot excluded from the rate.** Throughput is measured over drain (first completion → last). Boot is reported separately, never folded into the rate.
- **Alternating runs.** Sides alternate tightly so thermal drift and background load hit both engines evenly.

## Status

The claim "faster than Sidekiq" has been removed from the README and the site until the numbers support it. Closing the gap means batching the `Metrics::History` writes — the trade is dashboard counters lagging by the flush interval, and a hard crash dropping the unflushed window, which is the trade Sidekiq already makes.
