# Benchmarks

The latest published paired comparison (2026-08-07) does **not** show Wurk ahead of stock Sidekiq. These are historical measurements, not a current-release guarantee. A [re-run on 2026-11-03](#re-run-2026-11-03) at a later commit does not either.

Two different benchmark suites live in `bench/`. They answer different questions and only one of them compares against Sidekiq.

| Suite | Question | Command | Gates merges |
|---|---|---|---|
| `bench/*.rb` | Did *this PR* slow wurk down vs `main`? | `rake bench` | Flags only — [`.github/workflows/bench.yml`](../.github/workflows/bench.yml) comments a regression beyond both runs' error bounds plus `BENCH_REGRESSION_PCT` (default 5%) on the PR; not a required check |
| `bench/vs_sidekiq.rb` | Is wurk faster than *stock Sidekiq*? | `rake bench:vs_sidekiq` | No |

The regression check can be fully green while wurk is slower than Sidekiq. It measures wurk against its own past self. Do not read `rake bench` as a competitive result.

## Throughput vs stock Sidekiq

wurk 1.4.0 · sidekiq 8.1.6 · ruby 3.4.7 (x86_64-linux) · local Redis 7.4.10 · 5000 jobs/run · 12 runs per topology (4 invocations × 3 runs), paired per-run ratio (`wurk_i / sidekiq_i` within the same run, which cancels drift a median-of-medians would carry). Measured 2026-08-07, the latest published paired comparison; these results describe those engine versions and that environment, not a current-release guarantee. Reproduce with `bin/rake bench:vs_sidekiq`.

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

In that published comparison, Wurk was at parity with stock Sidekiq on `cpu` and `io` at both topologies. It was still behind on `noop` — pure framework overhead, where the extra Redis commands below cost the most — and on boot. This is a large move from the numbers this doc previously published (noop 0.45×/0.49×, cpu 0.81×/0.86×, io 0.74×/0.66×), but it is not a "faster than Sidekiq" result; see [Status](#status).

Forking does not close the gap. A stock Sidekiq user reaches multi-core by running N processes — that is the second table. The swarm's advantage is copy-on-write memory and a single supervisor, not throughput.

The run carried unrelated background load on the host for part of the session, which is why the per-invocation spread (min/max above) is wide — the paired-ratio median is the number to trust, not any single run. Full per-invocation record: [`docs/plans/2026/08/06/101-faster-than-sidekiq/08-measurements.md`](plans/2026/08/06/101-faster-than-sidekiq/08-measurements.md).

## Re-run 2026-11-03

The same harness at a later commit: the 1.10.0 code plus the change [below](#what-earned-its-place-and-what-did-not), stock Sidekiq 8.1.6, ruby 3.4.7 without YJIT, local Redis 7.0.15, 5000 jobs/run, 12 paired runs per topology. Ratios below 1.00 mean Wurk is slower. Q1 and Q3 are the quartiles of the 12 paired ratios. The host carried light unrelated load (load average 2 to 4). The tables above stay the published headline until this is republished with its raw record.

| Topology and workload | Median | Q1 | Q3 | Min | Max |
|---|---|---|---|---|---|
| 1p × 5t noop | 0.87× | 0.86× | 0.90× | 0.82× | 0.93× |
| 1p × 5t cpu | 0.97× | 0.96× | 0.98× | 0.93× | 1.00× |
| 1p × 5t io | 0.99× | 0.98× | 1.01× | 0.96× | 1.06× |
| 4p × 5t noop | 0.89× | 0.85× | 0.91× | 0.83× | 0.99× |
| 4p × 5t cpu | 1.00× | 0.96× | 1.03× | 0.95× | 1.43× |
| 4p × 5t io | 0.98× | 0.97× | 0.98× | 0.94× | 1.01× |

Boot to first job, median: Sidekiq 0.54s and Wurk 0.70s at 1 process, Sidekiq 0.54s and Wurk 0.73s at 4. Wurk is the slower one. `cpu` and `io` are within about 3% of Sidekiq, `noop` and boot are still behind, and this is not a "faster than Sidekiq" result. The harness hand-builds its payloads, so the change below is not on its clock: a difference from the published tables is a difference of host and commit.

### Enqueue

Same args, single thread, Redis on loopback, 10 paired rounds, wall time per job. `1.10.0` is an identical copy of the code before the change below; the A/A column compares a second such copy to it.

| Path | Sidekiq | 1.10.0 | Now | Now vs 1.10.0, median [Q1, Q3] | A/A control | Allocations per job, 1.10.0 → now (Sidekiq) |
|---|---:|---:|---:|---|---|---|
| `push_bulk` of 1000 | 6.8µs | 15.0µs | 9.4µs | 0.62 [0.60, 0.64] | 1.03 [0.93, 1.07] | 12 → 9 (7) |
| `perform_async` | 153µs | 171µs | 171µs | 1.00 [0.97, 1.04] | 1.05 [0.98, 1.07] | 66 → 66 (67) |

`push_bulk` was 2.2× slower than Sidekiq and is now 1.4× slower. `perform_async` did not change and is still behind.

## Re-run 2026-11-11 @ 8a4eda4 (release 1.12.0)

One serial pass on one host: Wurk at release 1.12.0 against stock Sidekiq (release 8.1.6), ruby 3.4.2 +YJIT, a private local Redis per bench, load average about 1.0 (the host's idle baseline). The comparison is 5 runs of 5000 jobs, 1 process × 5 threads, median. Raw output is in [`docs/benchmarks/2026-11-11/`](benchmarks/2026-11-11/). The published headline above stays until it is republished with paired ratios; these numbers agree with it.

| workload | Sidekiq | Wurk | ratio |
|---|---|---|---|
| `noop` | 6747 jobs/s (±1%) | 5782 jobs/s (±4%) | 0.86× |
| `cpu` | 402 jobs/s (±2%) | 393 jobs/s (±2%) | 0.98× |
| `io` | 792 jobs/s (±2%) | 795 jobs/s (±4%) | 1.00× |

Boot to first job: Sidekiq 0.35s, Wurk 0.49s. Wurk is slower on `noop` and boot, and at parity on `cpu` and `io`.

### Where the noop gap goes

CPU per job (`CLOCK_PROCESS_CPUTIME_ID`, all threads, over the drain window) tracks wall time per job on both sides: the `noop` gap is CPU work, not waiting on Redis. Sidekiq 145.0 µs/job (user 79.8, sys 65.2, 113 allocations); Wurk 170.1 µs/job (user 96.9, sys 72.1, 129 allocations).

`bin/profile vs_sidekiq` profiles the same noop job through the real `wurk` and `sidekiq` CLIs with StackProf (3 profiled runs per side, 50,000 jobs; samples cover 91–92% of measured CPU) and charges each sample to the innermost framework stage; a Redis round trip counts toward the stage that issued it.

| stage | Sidekiq µs/job | Wurk µs/job | Δ | share of gap |
|---|---|---|---|---|
| fetch (Wurk: + pipelined ACK) | 42.2 | 54.8 | +12.6 | 58% |
| job logger + log write | 30.3 | 34.1 | +3.8 | 17% |
| ACK bookkeeping | 0.0 | 3.2 | +3.2 | 14% |
| other built-in middleware | 0.0 | 1.8 | +1.8 | 8% |
| middleware chain walk | 2.4 | 4.0 | +1.6 | 8% |
| job body | 41.0 | 41.9 | +0.9 | 4% |
| metrics middleware | 4.9 | 5.5 | +0.7 | 3% |
| GC | 4.6 | 5.2 | +0.6 | 3% |
| payload parse, retry wrappers, heartbeat | — | — | ≈0 | 0% |
| stats + work state | 3.9 | 3.5 | −0.4 | −2% |
| processor dispatch | 6.8 | 4.4 | −2.5 | −11% |
| **total** | 139.5 | 161.3 | +21.9 | 100% |

A cost cut proceeds only for a stage that is at least 5% of this gap. Full per-frame tables: [`vs_profile.txt`](benchmarks/2026-11-11/vs_profile.txt).

### Boot and require cost

`bin/rake bench:require_profile` (bench/require_profile.rb) loads each entry point in a fresh interpreter: feature and allocation counts are deterministic, times are the median of 10 runs.

| entry | ms | features | Wurk/Sidekiq files | allocations | RSS added |
|---|---|---|---|---|---|
| `require "wurk"` | 132 | 248 | 159 | 60.6k | 16.4 MB |
| `exe/wurk` to first fetch | 183 | 250 | 159 | 81–83k | 18.3 MB |
| `require "wurk/rails"` (on top of Rails) | 87 | 192 | 165 | 40.7k | 6.5 MB |
| `require "sidekiq"` | 60 | 100 | 20 | 27.9k | 10.4 MB |
| `sidekiq` to first fetch | 110 | 129 | 35 | 50–52k | 12.9 MB |

Shared dependencies (openssl, uri, redis-client) cost about the same on both sides; the gap is Wurk's own files. Per-file tables: [`require_profile.txt`](benchmarks/2026-11-11/require_profile.txt).

### Memory per process

`bin/rake bench:rss_soak` boots `wurkswarm` with 4 children × 5 threads on `test/dummy` and pushes 100k plain jobs, reading `/proc/<pid>/smaps_rollup` per child.

| jobs | Rss | Pss | Private_Dirty | shared ratio |
|---|---|---|---|---|
| 0 | 81 MB | 33 MB | 22 MB | 0.73 |
| 10k | 96 MB | 53 MB | 43 MB | 0.55 |
| 100k | 98 MB | 55 MB | 45 MB | 0.54 |

After warmup (the first 10k jobs) Pss grows 160–220 kB per 10k jobs per child. Redis: 25 keys and 1.95 MB at 100k jobs. A slope over 100k jobs is not a leak verdict; that is the long soak's job.

### Soak

`bin/rake bench:soak` (bench/soak/) runs a mixed workload (plain, scheduled, retry, unique, limiter, iterable, status, nested batches, cron) against a 4-child swarm and its own AOF-backed Redis, injects faults, and checks a jid ledger: every pushed jid completed or dead, every extra run attributed to a window [`reliability.md`](reliability.md) documents. Short mode, 150s of load:

| pushed | completed | lost | duplicates | unattributed | batch callbacks | faults |
|---|---|---|---|---|---|---|
| 19,435 | 19,435 | 0 | 1 deferred ACK, 1 Redis outage | 0 | 3434/3434 | 3 SIGKILL (1 child, 2 parent), 1 SIGTERM, 5 rolling restarts, 2 Redis restarts, 1 pause |

The 24h run is pending (`SOAK_MODE=long SOAK_DURATION=86400`). Report: [`soak_short.json`](benchmarks/2026-11-11/soak_short.json).

### Feature and dashboard costs

Seven benches count Redis round trips client-side (`bench/algo/support.rb`) and exit 1 over a recorded budget; `bin/rake bench:algo_counts` runs the counts in CI, `bin/rake bench:algo` adds rates. These are the "before" values for the cost cuts in plan 101 slices 07 and 21.

| bench | measures | before |
|---|---|---|
| `dashboard_paging.rb` | page 0 vs page 999, 25 rows | queue 5 vs 1003 round trips; batches 52 vs 25,276; SSE tick 9 round trips (3Q+P+12 commands) |
| `feature_commands.rb` | extra round trips per job | concurrent limiter 7 per job (plain: 1) |
| `cron_tick.rb` | 500 loops | tick 1001 round trips; 50 never-fired yearly loops: 1.2s per tick |
| `metrics_query.rb` | top jobs over 720h, 200 classes | 4320 HGETALL, 2.59M field pairs, 13M objects per query |
| `fast_delete.rb` | delete by class on a 100k queue | Redis blocked 315 ms per call |
| `reaper_sweep.rb` | 1M unrelated keys | 1001 round trips per sweep |
| `sorted_set_bulk.rb` | retry all, 10k entries | 2.02 round trips per entry |

Rates: [`algo.txt`](benchmarks/2026-11-11/algo.txt).

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

### Commands per heartbeat

Every process beats every 10 seconds whatever its throughput, so the beat is a fixed per-process cost, not a per-job one. `bin/rake bench:command_count` counts it after the per-job table, over 10 idle beats per case with `INFO commandstats`, and fails if any case moves either way:

| case | per beat | commands |
|---|---|---|
| plain | 5 | SADD, HSET, EXPIRE, UNLINK (no job running), RPOP of the signal list |
| statsd follower | 6 | plain + GET of the leader lock |
| statsd leader | 7 | statsd follower + one LLEN per queue (one queue here) |

`plain` is a process without `config.dogstatsd`, leader or not. A busy process swaps the UNLINK for a MULTI/UNLINK/HSET/EXPIRE/EXEC rewrite of its work hash, and a process holding [global-concurrency](plans/2026/08/07/101-beyond-sidekiq/10-global-concurrency.md) slots adds a slot-refresh script; neither case is counted. The cases run against a planted `dear-leader` value, so the leader GET is counted but leader election is not.

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
  semantics have exactly one implementation. The [1.7.0 release notes](changelog/1.7.0.md)
  report **~2.1µs → ~0.48µs per command**, a historical measurement, not a new
  timing run here. Reproduce with `bin/rake bench:command_builder`. The ACK's
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
`bench/command_builder.rb` is in the advisory regression check so a fast path
that stops firing can be flagged in the PR comment. The benchmark job is not a
required check and does not block merges.

### What earned its place, and what did not

Each candidate ran against an identical copy of the code, next to an A/A control that compares a second copy to it. That control is the noise floor.

| Change | Measured, median [Q1, Q3] | A/A in the same run | Verdict |
|---|---|---|---|
| Normalize `push_bulk` once per slice | `push_bulk` wall 0.62 [0.60, 0.64] | 1.03 [0.93, 1.07] | **Shipped** |
| Skip Wurk's own no-op client middleware (Batch, Collapse) | `push_bulk` wall, on top of the above, 0.93 [0.89, 0.98] | 1.03 [1.00, 1.07] | **Dropped.** Real but small, and a skip decided ahead of the call has to stay correct against a `prepend` at any time; stock Sidekiq would run it |
| Skip no-op server middleware | worker CPU per noop job 1.00 [0.97, 1.04] | 1.00 [0.97, 1.02] | **Dropped.** Inside the noise |
| Allocation-free logger context | `format_context` 2.4µs to 2.6µs, in isolation | | **Dropped.** 6 fewer allocations per job, no time |
| `call_v` on the ACK pipeline | ACK build 7.0µs to 6.0µs, in isolation | | **Dropped.** About 1µs of a job, and the fetch path stays untouched |
| RESP writer as a redis-client driver | one fetch pipeline encodes in 7.7µs instead of 22.8µs, in isolation | | **Dropped.** Whole-job gain stayed close to the noise, against a new default driver for every adopter that subclasses redis-client internals and costs about 1.4MB per process. The option if a later measurement justifies it, on an opt-in basis |

What shipped touches `push_bulk` only: no code on the path a worker runs changed.

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

`bin/rake bench` runs the harnesses the regression check reads. Each takes its size
from the environment, so a slow laptop can shrink a run without editing the
harness:

| Env var | Default | Harness | Meaning |
|---|---|---|---|
| `WURK_BENCH_CAP` | `20` | `bench/fetch_capped.rb` | in-flight fetch cap |
| `WURK_BENCH_CMD_JOBS` | `500` | `bench/command_count.rb` | jobs pushed while counting Redis commands |
| `WURK_BENCH_CMD_BUDGET` | `3` | `bench/command_count.rb` | commands per job the run is allowed before it fails |
| `WURK_BENCH_CMD_BASELINE` | `3` | `bench/command_count.rb` | commands per job the comparison treats as the baseline |
| `WURK_BENCH_CMD_PLAIN_BEAT` | `5` | `bench/command_count.rb` | commands per heartbeat, no statsd client |
| `WURK_BENCH_CMD_FOLLOWER_BEAT` | `6` | `bench/command_count.rb` | commands per heartbeat, statsd client, not the leader |
| `WURK_BENCH_CMD_LEADER_BEAT` | `7` | `bench/command_count.rb` | commands per heartbeat, statsd client, leader |
| `WURK_BENCH_MEM_JOBS` | `2000` | `bench/memory.rb` | jobs executed per RSS sample |
| `WURK_BENCH_MEM_SAMPLES` | `5` | `bench/memory.rb` | RSS samples taken |
| `WURK_BENCH_SWARM_CHILDREN` | `2` | `bench/swarm_boot.rb` | children forked per boot sample |
| `WURK_BENCH_MAX_TIME` | unset | every benchmark/ips harness | ceiling on each script's timed window, seconds (can shorten, never lengthen; CI bench sets 4) |
| `WURK_BENCH_MAX_WARMUP` | unset | every benchmark/ips harness | ceiling on each script's warmup, seconds (CI bench sets 1) |
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

**Published result (2026-08-07): wurk was at parity with stock Sidekiq on `cpu` and `io` at both topologies measured, and still behind on `noop` and on boot to first job.** Not a "faster than Sidekiq" result. Full per-invocation record and the verdict against the plan's "done when" criteria: [`docs/plans/2026/08/06/101-faster-than-sidekiq/08-measurements.md`](plans/2026/08/06/101-faster-than-sidekiq/08-measurements.md). The [2026-11-03 re-run](#re-run-2026-11-03) changes the ratios, not the conclusion.
