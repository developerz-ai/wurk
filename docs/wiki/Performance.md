# Performance

**Wurk is not ahead of stock Sidekiq on throughput.** Measured at **0.87×–1.02×** depending on workload: parity on CPU- and IO-bound jobs, behind on empty jobs and on boot. Ratios below 1.00 mean Wurk is slower.

wurk 1.5.0 · sidekiq 8.1.6 · ruby 3.4.7 · local Redis 7.4.10 · 5000 jobs/run · 12 runs per topology, paired per-run ratio. Measured 2026-08-07.

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

Boot to first job: 0.56s → 0.72s (1p×5t) and 0.60s → 0.78s (4p×5t), Sidekiq → Wurk.

## Why `noop` is behind

`noop` is an empty `perform` — pure framework overhead, so it is where the per-job Redis traffic shows up undiluted.

| Engine | Commands per job | What they are |
|---|---|---|
| Sidekiq | 1 | `BRPOP`. In-flight jobs are lost if the worker is killed. |
| Wurk | 3 | `LREM` + `DEL` retiring the previous job, then `LMOVE` claiming this one — **one pipeline, one round trip** |

Those extra commands buy reliable fetch, which in Sidekiq is the paid Pro `super_fetch` feature and is Wurk's only mode. 3 commands/job is the settled floor: the poison-pill `DEL` is what distinguishes a reclaimed payload from a fresh one, and no Lua rewrite folds it away.

## What forking actually buys

Not throughput. A stock Sidekiq user reaches multi-core by running N processes — that is exactly the second table above, and it is a tie. The fork-based swarm buys **copy-on-write memory** and **one supervisor** (PID supervision, rolling restarts, one unit to deploy) instead of N unrelated processes.

## Two suites — do not confuse them

| Suite | Question | Gates merges |
|---|---|---|
| `bin/rake bench` | Did this PR slow Wurk down vs its own past self? | Yes — >5% blocks |
| `bin/rake bench:vs_sidekiq` | How does Wurk compare to stock Sidekiq? | No |

A green `rake bench` says **nothing** about Sidekiq. It is a regression gate against Wurk's own history.

## Reproduce it

```bash
bin/rake bench:vs_sidekiq                            # 1 proc × 5 threads
WURK_BENCH_VS_PROCESSES=4 bin/rake bench:vs_sidekiq  # swarm vs 4 sidekiq procs
```

Needs a local Redis. The Sidekiq side runs from an isolated bundle with `RUBYOPT`/`RUBYLIB` cleared, because inside this repo's bundle `bundle exec sidekiq` would boot Wurk's shim — the two distinct versions printed in the header are the proof the control is real. Identical versions mean the run is void.

**Gotchas:** `cpu` is the noisiest shape (0.67×–1.41× across 12 runs) — a single run means nothing, only the paired median does. Boot is reported separately and never folded into the throughput rate.

Full method, per-invocation records, the Ruby-side profiling work, and the tuning history: **[docs/benchmarks.md](https://github.com/developerz-ai/wurk/blob/main/docs/benchmarks.md)**.
