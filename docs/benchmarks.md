# Benchmarks

Wurk is **not** currently faster than stock Sidekiq. Measured, published, and tracked here rather than claimed.

Two different benchmark suites live in `bench/`. They answer different questions and only one of them compares against Sidekiq.

| Suite | Question | Command | Gates merges |
|---|---|---|---|
| `bench/*.rb` | Did *this PR* slow wurk down vs `main`? | `rake bench` | Yes — [`.github/workflows/bench.yml`](../.github/workflows/bench.yml), >5% regression blocks |
| `bench/vs_sidekiq.rb` | Is wurk faster than *stock Sidekiq*? | `rake bench:vs_sidekiq` | No |

The regression gate can be fully green while wurk is slower than Sidekiq. It measures wurk against its own past self. Do not read `rake bench` as a competitive result.

## Throughput vs stock Sidekiq

wurk 1.5.0 · sidekiq 8.1.6 · ruby 3.4.7 (x86_64-linux) · local Redis 7.4.10 · 5000 jobs/run · 12 runs per topology (4 invocations × 3 runs), paired per-run ratio (`wurk_i / sidekiq_i` within the same run, which cancels drift a median-of-medians would carry). Measured 2026-08-07; reproduce with `bin/rake bench:vs_sidekiq`.

Ratios below 1.00 mean wurk is slower.

**1 process × 5 threads**

| Workload | Ratio (median of 12) | min | max |
|---|---|---|---|
| noop | 0.87× | 0.74× | 1.08× |
| cpu | 0.99× | 0.78× | 1.21× |
| io | 0.99× | 0.84× | 1.11× |

**4 processes × 5 threads** — `wurkswarm` (4 forks) vs 4 independent `sidekiq` processes

| Workload | Ratio (median of 12) | min | max |
|---|---|---|---|
| noop | 0.95× | 0.71× | 1.19× |
| cpu | 1.02× | 0.67× | 1.41× |
| io | 0.97× | 0.60× | 1.26× |

Boot to first job, median over all runs per side:

| Topology | Sidekiq | Wurk |
|---|---|---|
| 1p × 5t | 0.56s | 0.72s |
| 4p × 5t | 0.60s | 0.78s |

Wurk is at parity with stock Sidekiq on `cpu` and `io` at both topologies. It is still behind on `noop` — pure framework overhead, where the extra Redis commands below cost the most — and on boot. This is a large move from the numbers this doc previously published (noop 0.45×/0.49×, cpu 0.81×/0.86×, io 0.74×/0.66×), but it is not a "faster than Sidekiq" result; see [Status](#status).

Forking does not close the gap. A stock Sidekiq user reaches multi-core by running N processes — that is the second table. The swarm's advantage is copy-on-write memory and a single supervisor, not throughput.

The run carried unrelated background load on the host for part of the session, which is why the per-invocation spread (min/max above) is wide — the paired-ratio median is the number to trust, not any single run. Full per-invocation record: [`docs/plans/2026/08/06/101-faster-than-sidekiq/08-measurements.md`](plans/2026/08/06/101-faster-than-sidekiq/08-measurements.md).

## Workload shapes

"Faster" is meaningless without naming the work. Three shapes, all in `bench/vs_sidekiq/job.rb`:

| Shape | Body | Measures |
|---|---|---|
| `noop` | empty `perform` | pure framework overhead — fetch, middleware, dispatch, ack |
| `cpu` | fixed arithmetic loop | holds the GVL; the shape fork-based parallelism exists for |
| `io` | `sleep` | releases the GVL; threads and forks both scale — the honest control |

`cpu` is the noisiest shape (min/max spans 0.67×–1.41× across the 12 paired runs above). Single runs of it mean nothing — only the paired-ratio median across many runs is worth reading.

## Why wurk is still behind on `noop`

Redis commands per job, counted with `INFO commandstats` over 500 jobs. Reproduce with `bin/rake bench:command_count`, which prints the breakdown below and is the source these numbers are published from:

```text
wurk — 500 noop jobs drained from queue:default (INFO commandstats)

  commands  per job  command
       500     1.00  lrem
       500     1.00  lmove
       500     1.00  del
  --------  -------
      1500     3.00  total
```

| Engine | Per job | Breakdown |
|---|---|---|
| Sidekiq | 1 | 1 BRPOP. Stat counters buffered in memory, flushed on a timer. |
| Wurk | 3 | 1 pipeline, 1 round trip: LREM + DEL retiring the previous job, then the LMOVE claiming this one |

**3.00 commands/job, at budget and at the recorded baseline** — down from the ~10 commands / 4 round trips this doc previously published. What is left, and the verdict on it:

- **Reliable fetch** — the same **one round trip** per job as BRPOP, with three commands inside it rather than one. This is [`Wurk::Fetcher::Reliable`](reliability.md), the default. Sidekiq's equivalent (`super_fetch`) is a paid Pro feature; stock Sidekiq's BRPOP loses in-flight jobs when a worker is killed. The extra commands buy a guarantee, and are not a defect. Note the table counts *commands*, not round trips — `INFO commandstats` cannot see a pipeline.
- **The poison-pill `DEL`** is a deliberate keeper, not an oversight — a reclaimed payload is byte-identical to a fresh one, so only the counter distinguishes them, and Lua can't fold this away. 3 commands/job is the settled floor; the plan's original ≤2 target is not reachable without dropping the poison-pill guarantee.

Costs that used to dominate this table are gone:

- **Metrics** were 6 of the old ~10 — `Wurk::Metrics::History` wrote 2 HINCRBY + EXPIRE per job, twice over. They are now folded in memory per (class, minute) and flushed every ≤5s, the same trade Sidekiq makes; see [Write cadence](metrics.md#write-cadence-and-what-a-hard-kill-costs) for what that costs on a hard kill. A worker still pays one pipeline per Redis pool per flush, carrying 6 commands per (class, minute) bucket, which rounds to nothing per job at any real throughput and does not appear above.
- **The paused SET** was the seventh, an `SMEMBERS` on every fetch pass; it is now read at most once per [`PAUSED_TTL`](reliability.md#fetch-order-and-polling) per fetcher.
- **The ACK** was a round trip of its own, sent the moment a job finished. Its `LREM` + `DEL` now [ride the next fetch's pipeline](reliability.md#the-ack-rides-the-next-fetch) — the same commands, one fewer round trip — at the cost of a wider window in which a hard kill re-runs an already-finished job.

`noop` is pure framework overhead, so it is exactly where 3 commands per job against Sidekiq's 1 still costs — it is the shape that has to cross 1.0× before wurk stops being behind here at all.

Global per-queue concurrency capping (`config.global_concurrency`,
[`10-global-concurrency.md`](plans/2026/08/07/101-beyond-sidekiq/10-global-concurrency.md))
shipped without moving this table. Unconfigured, `Wurk::Fetcher::Capped` resolves a
boot-time boolean and falls straight through to the same `Reliable` loop counted above —
still 3.00 commands/job, and `rake bench` unconfigured stayed within noise of `main`
across the whole gate (enqueue, fetch+execute, bulk enqueue, swarm boot, memory) —
see the slice doc's
[ship decision](plans/2026/08/07/101-beyond-sidekiq/10-global-concurrency.md#ship-decision-2026-08-09)
for those numbers.

A queue that *is* capped pays for it, honestly, and that cost has not been benchmarked:
`fetch_slot.lua` folds the gate into the fetch so a capped queue spends the same one
round trip an uncapped one does, but its script runs `TIME`, `ZREMRANGEBYSCORE`, `ZCARD`
and `ZADD` around the `LMOVE`, and nobody has put an i/s number on that.
[`10-global-concurrency-measurement.md`](plans/2026/08/07/101-beyond-sidekiq/10-global-concurrency-measurement.md)
is **not** that number — it is the pre-implementation prototype, which priced the
bracketing shape (a bare acquire and release around the fetch, 2.2x–2.6x) that the real
implementation exists to avoid. Read it as the upper bound it is.

## The other half: Ruby-side cost per job

Round trips are the headline, but they are not the whole bill. Once the fetch
pipeline was down to one round trip, the next-largest movable cost was the Ruby
that runs *between* `conn.call(...)` and the socket. `bin/profile` samples it
against a real Redis:

```bash
bin/profile                 # fetch+execute, CPU samples
bin/profile enqueue         # the client push path
bin/profile fetch --alloc   # allocation counts, for GC pressure
```

What that turned up, and what was done about it. Percentages are that frame's
share of a 50k-iteration `fetch+execute` CPU profile, before → after:

| Frame | Before | After |
|---|---:|---:|
| `RedisClient::CommandBuilder#generate` | 4.4% | — |
| `Enumerable#flat_map` (its `flat_map`) | 4.3% | 2.1% |
| `Process.pid` | 1.0% | — |
| `Wurk::JobLogger#context_hash` | 1.4% | 1.0% |

About 6% of the profile, on a path where roughly a quarter of it is socket
syscalls that no amount of Ruby can remove. The same three changes move
`bench/memory.rb` — the one gate here that is deterministic rather than
wall-clock, since it counts allocations — from **6.49 to 6.76 jobs per 1,000
allocations**, about 4% fewer allocations per job. The throughput benches also
improved on the same machine, but not by an amount worth publishing: this host
was under unrelated load for the "before" run, and a paired re-measurement
against stock Sidekiq has not been done since. The vs-Sidekiq table above is
therefore unchanged and still the number to quote.


- **Command normalization was 4.4% of fetch+execute.** redis-client's default
  builder splices Hash arguments with a `flat_map` and stringifies the result
  with a `map!` — two array allocations and two per-element type dispatches for
  a command whose arguments are already Strings, which is what all three
  commands per job are. [`Wurk::CommandBuilder`](../lib/wurk/command_builder.rb)
  short-circuits that case and hands anything else (a Hash to splice, a Symbol
  or number to stringify, kwargs) straight to redis-client's own builder, so the
  semantics have exactly one implementation. Measured with
  `bin/rake bench:command_builder`: **~2.2µs → ~0.45µs per command**. The ACK's
  `LREM` count is a pre-stringified `'1'` for the same reason — one Integer
  argument would send the whole command back through the slow path.
  The shortcut has one trap worth naming: redis-client splats `**kwargs` before
  calling the builder, so a `call` with no keywords arrives with an *empty
  Hash*, never `nil`. A guard that only tested `.nil?` sent the whole hot path
  down the slow branch while every output-equality test still passed — which is
  why `Wurk::CommandBuilder.fast?` is public and asserted directly.
- **`Process.pid` was 1.0%.** glibc dropped its `getpid` cache in 2.25, so it is
  a real syscall — ~640ns — and the hot path called it twice per job
  (`Component.tid` and the fetcher's per-queue key cache, both of which read it
  only to notice a fork). [`Wurk::PidCache`](../lib/wurk/pid_cache.rb) memoizes
  it and refreshes in the child half of every fork via `Process._fork`, which is
  the only event that can change the answer.
- **`JobLogger#context_hash` re-read `config[:logged_job_attributes]`** through
  the capsule's delegating `[]` on every job, to walk a list that is fixed once
  the configuration freezes at launch. Read once, in the constructor.

And the cost paid before the first job runs at all — `require "wurk"`, which is
boot time for every worker, every fork in a swarm, and every Rails app that
loads the gem. It was **~290ms**; it is now **~186ms**. Three subtrees were
pulling heavy stdlib in eagerly for code most processes never reach:

| Required at load | By | Cost | Actually needed when |
|---|---|---:|---|
| `optparse`, `yaml`, `erb` | `Wurk::CLI` | ~45ms | `exe/wurk` parses argv or a config file |
| `tempfile` (+ `tmpdir`) | `Wurk::Profiler` | ~19ms | vernier is loaded *and* a job is profiled |
| `erb`, `cgi` | `Wurk::Web::Extension` | ~40ms | a host registered a Web extension and a request arrived |

Each is now required inside the one method that uses it. `require` is
idempotent, so every call after the first is a `$LOADED_FEATURES` hash lookup.
What remains is dominated by `openssl` (~58ms), which redis-client's own config
requires and Wurk cannot avoid.

None of these change a Redis key, a command sequence, or a job-JSON field —
they are the same wire traffic with less Ruby in front of it.
`bench/command_builder.rb` is in the regression gate so a fast path that stops
firing shows up as a merge-blocking delta rather than a slow drift nobody
notices.

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
| `WURK_BENCH_VS_TIMEOUT` | `180` | seconds one (shape, engine) run may take before the driver gives up |

`WURK_BENCH_VS_SHAPE` and `WURK_BENCH_VS_DONE_KEY` are set by the driver in each
child worker's environment (`bench/vs_sidekiq/child_env.rb`) — read by
`bench/vs_sidekiq/job.rb`, not set by hand.

### The regression benches

`bin/rake bench` runs the harnesses the merge gate reads. Each takes its size
from the environment, so a slow laptop can shrink a run without editing the
harness:

| Env var | Default | Harness | Meaning |
|---|---|---|---|
| `WURK_BENCH_CAP` | `20` | `bench/fetch_capped.rb` | in-flight fetch cap |
| `WURK_BENCH_CMD_JOBS` | `500` | `bench/command_count.rb` | jobs pushed while counting Redis commands |
| `WURK_BENCH_CMD_BUDGET` | `3` | `bench/command_count.rb` | commands per job the run is allowed before it fails |
| `WURK_BENCH_CMD_BASELINE` | `3` | `bench/command_count.rb` | commands per job the comparison treats as the baseline |
| `WURK_BENCH_MEM_JOBS` | `2000` | `bench/memory.rb` | jobs executed per RSS sample |
| `WURK_BENCH_MEM_SAMPLES` | `5` | `bench/memory.rb` | RSS samples taken |
| `WURK_BENCH_SWARM_CHILDREN` | `2` | `bench/swarm_boot.rb` | children forked per boot sample |
| `WURK_BENCH_SWARM_SAMPLES` | `8` | `bench/swarm_boot.rb` | boot samples taken |

### Comparing two runs

`bin/bench-compare BASELINE.txt CURRENT.txt` prints the per-benchmark delta and
is what fails the `bench vs base` check:

| Env var | Default | Meaning |
|---|---|---|
| `BENCH_REGRESSION_PCT` | `5` | signal margin, in percent, on top of both runs' reported `± error` before a slowdown counts as a regression |

A drop is flagged only when `drop% > base_err% + head_err% + BENCH_REGRESSION_PCT`,
so two ±7% samples differing by ~14% with no code change do not block a merge.
Speedups are always reported and never gated.

## Fairness

The comparison is only worth reading if the control is real. What the harness guarantees:

- **Stock Sidekiq is actually stock.** Wurk ships `lib/sidekiq.rb` (the drop-in require shim) and Bundler puts every bundled gem's `lib/` on `$LOAD_PATH` — so inside the repo bundle, `bundle exec sidekiq` boots **wurk**. The Sidekiq side therefore runs from `bench/vs_sidekiq/Gemfile` with `RUBYOPT` and `RUBYLIB` cleared. The two distinct versions printed in the header are the proof; identical versions mean the run is void.
- **Identical job code.** `include Sidekiq::Job` resolves to wurk's compat module on one side and the real gem on the other. Same file, both sides.
- **Identical payloads.** Jobs are hand-built into the shared Redis key schema and pushed by the driver, so neither side's client library is on the clock.
- **Boot excluded from the rate.** Throughput is measured over drain (first completion → last). Boot is reported separately, never folded into the rate.
- **Alternating runs.** Sides alternate tightly so thermal drift and background load hit both engines evenly.

## Status

The claim "faster than Sidekiq" has been removed from the README and the site, and may not be added back until the numbers above support it — they do not yet (CLAUDE.md pillar 3).

The `Metrics::History` batching and the ack piggyback that closed the round-trip gap have both landed and are reflected in the numbers above — **four round trips per job down to one**, and ~10 commands down to 3 — at the cost of dashboard counters lagging by the flush interval, a hard crash dropping the unflushed window, and a wider window in which a hard kill re-runs an already-finished job. The throughput and command-count tables above are re-measured post-landing, not carried over from before that work.

**Net result: wurk is at parity with stock Sidekiq on `cpu` and `io` at both topologies measured, and still behind on `noop` and on boot to first job.** Not a "faster than Sidekiq" result. Full per-invocation record and the verdict against the plan's "done when" criteria: [`docs/plans/2026/08/06/101-faster-than-sidekiq/08-measurements.md`](plans/2026/08/06/101-faster-than-sidekiq/08-measurements.md).
