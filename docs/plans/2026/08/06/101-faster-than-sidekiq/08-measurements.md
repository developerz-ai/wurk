# 08 — Final measurement record

> Evidence for step 6 of [`08-bench-gate-verify.md`](08-bench-gate-verify.md), taken after slices 02–07 landed (through `8571520`). This file is the raw record; republishing it into `docs/benchmarks.md` is the next task. Numbers here are copied from the run output, never retyped from memory.

## Environment

| | |
|---|---|
| Date | 2026-08-07 |
| Host | 12-core x86_64 linux, **not idle** — see the caveat below |
| Ruby | 3.4.7 (x86_64-linux) +PRISM |
| Redis | 7.4.10, local, `redis://localhost:6379` |
| Engines | wurk 1.4.0 vs sidekiq 8.1.6 |
| Harness | `bench/vs_sidekiq.rb`, 5000 jobs/run, 3 runs per invocation, 4 independent invocations per topology (n=12) |

**Load caveat, stated up front because it is the biggest source of error here.** The box carried unrelated background work for part of the session (a qemu VM at ~150% CPU, a `bun` build at ~100%, load average 8–10 on 12 cores). The harness alternates sides tightly, so drift hits both engines, but it widens every spread: the same 1p×5t `noop` comparison read 1.03× in the first invocation and 0.80× in the second. Twelve runs per topology across four separate invocations, and the paired estimator below, are how that is absorbed. A publication-grade rerun belongs on a quiet machine.

## 1. `rake bench` — the regression gate

Six full `rake bench` runs on this branch, best-of-3 per side fed to `bin/bench-compare` — the same shape `.github/workflows/bench.yml` runs. This branch carries no `lib/` change, so both sides are the same code and the table is the harness's own noise floor.

```
| benchmark                          | base (i/s) | head (i/s) |     Δ |
|------------------------------------|-----------:|-----------:|------:|
| wurk enqueue                       |      4.03k |      3.96k | -1.6% |
| wurk fetch+execute                 |      3.28k |      3.33k | +1.6% |
| wurk hot-path (jobs/1k-alloc)      |          7 |          7 | +0.0% |
| wurk hot-path (retention-free/1k)  |      1.00k |      1.00k | +0.0% |
| wurk idle scheduler sweep          |      2.46k |      2.58k | +4.8% |
| wurk push_bulk(1000)               |         90 |         89 | -1.0% |
| wurk swarm boot                    |        110 |        115 | +4.3% |
```

**Green** — `bin/bench-compare` exits 0, all 7 labels present on both sides, worst delta −1.6% against a 5% margin.

## 2. `rake bench:vs_sidekiq` — throughput vs stock Sidekiq

### Fairness invariant

`docs/benchmarks.md` § Fairness: two **distinct** versions in the header or the run is void. All 8 invocations printed `wurk 1.4.0 vs sidekiq 8.1.6`; zero printed a matching pair. The comparison is against the real gem, not wurk under Sidekiq's name.

Getting there needed a harness fix — see § 4.

### Per-invocation medians (as printed)

**1 process × 5 threads**

| Invocation | noop | cpu | io | boot sidekiq / wurk |
|---|---|---|---|---|
| A | 1038 / 1071 → 1.03× | 159 / 161 → 1.01× | 689 / 579 → 0.84× | 0.65s / 0.76s |
| B | 1278 / 1022 → 0.80× | 170 / 163 → 0.96× | 673 / 626 → 0.93× | 0.61s / 0.73s |
| C | 1467 / 1324 → 0.90× | 216 / 213 → 0.98× | 752 / 736 → 0.98× | 0.51s / 0.70s |
| D | 1501 / 1297 → 0.86× | 202 / 196 → 0.97× | 717 / 746 → 1.04× | 0.53s / 0.68s |

**4 processes × 5 threads** (`WURK_BENCH_VS_PROCESSES=4`: one `wurkswarm` forking 4 children vs 4 independent `sidekiq` processes)

| Invocation | noop | cpu | io | boot sidekiq / wurk |
|---|---|---|---|---|
| A | 3738 / 3671 → 0.98× | 564 / 600 → 1.06× | 2721 / 2640 → 0.97× | 0.57s / 0.78s |
| B | 3647 / 3759 → 1.03× | 477 / 471 → 0.99× | 2412 / 2005 → 0.83× | 0.64s / 0.88s |
| C | 3907 / 3120 → 0.80× | 548 / 569 → 1.04× | 2564 / 2548 → 0.99× | 0.61s / 0.75s |
| D | 3198 / 3790 → 1.18× | 382 / 434 → 1.14× | 2751 / 1972 → 0.72× | 0.58s / 0.79s |

### Pooled across all 12 runs

Median of every run, both topologies. Ratios below 1.00 mean wurk is slower.

| Topology | Workload | Sidekiq | Wurk | Ratio |
|---|---|---|---|---|
| 1p × 5t | noop | 1424 jobs/s | 1134 jobs/s | 0.80× |
| 1p × 5t | cpu | 198 jobs/s | 197 jobs/s | 0.99× |
| 1p × 5t | io | 708 jobs/s | 729 jobs/s | 1.03× |
| 4p × 5t | noop | 3694 jobs/s | 3715 jobs/s | 1.01× |
| 4p × 5t | cpu | 550 jobs/s | 561 jobs/s | 1.02× |
| 4p × 5t | io | 2585 jobs/s | 2516 jobs/s | 0.97× |

### Paired per-run ratios — the estimator to quote

Within a run the harness measures sidekiq and then wurk on the same shape back to back, so `wurk_i / sidekiq_i` cancels the drift that a median of medians carries. This is the number to publish.

| Topology | Workload | Ratio (median of 12) | min | max |
|---|---|---|---|---|
| 1p × 5t | noop | **0.87×** | 0.74× | 1.08× |
| 1p × 5t | cpu | **0.99×** | 0.78× | 1.21× |
| 1p × 5t | io | **0.99×** | 0.84× | 1.11× |
| 4p × 5t | noop | **0.95×** | 0.71× | 1.19× |
| 4p × 5t | cpu | **1.02×** | 0.67× | 1.41× |
| 4p × 5t | io | **0.97×** | 0.60× | 1.26× |

Boot to first job, median over all 36 shape-runs per side:

| Topology | Sidekiq | Wurk |
|---|---|---|
| 1p × 5t | 0.56s | 0.72s |
| 4p × 5t | 0.60s | 0.78s |

## 3. `rake bench:command_count` — commands per job

```
wurk — 500 noop jobs drained from queue:default (INFO commandstats)

  commands  per job  command
       500     1.00  lrem
       500     1.00  lmove
       500     1.00  del
  --------  -------
      1500     3.00  total

✓ 3.00 commands/job, within the budget of 3.00 and at the recorded baseline of 3.00
```

**3.00 commands/job**, one round trip. Down from the ~10 commands / 4 round trips `docs/benchmarks.md` still publishes.

## 4. Harness fix this measurement required

`rake bench:vs_sidekiq` did not run at all under bundler 2.7. `child_env` cleared `RUBYOPT` and `RUBYLIB`, but `bundle exec` also exports `BUNDLER_SETUP` (rubygems requires it from `gem_prelude`, so clearing `RUBYOPT` does not stop it) and `GEM_HOME`/`GEM_PATH`, which pin the child to the parent bundle's gem dir. The Sidekiq side therefore resolved against wurk's bundle, where stock sidekiq is not installed, and `install_sidekiq_bundle` raised before a single job ran.

Fixed by clearing every channel (`BUNDLER_LEAKS` in `bench/vs_sidekiq.rb`) and pinned by `test/unit/bench_vs_sidekiq_env_test.rb`, which asks the installed bundler what it injects rather than hard-coding a list, so a new channel in a future bundler fails in the test suite instead of at measurement time.

## 5. Verdict against the plan's "Done when"

| Criterion (`overview.md:31-33`) | Result | Met |
|---|---|---|
| noop ≥ 1.0× at both topologies | 0.87× (1p), 0.95× (4p) | ✗ |
| io ≥ 1.0× at both topologies | 0.99× (1p), 0.97× (4p) | ✗ (parity, not ahead) |
| cpu ≥ 0.95× at both topologies | 0.99× (1p), 1.02× (4p) | ✓ |
| boot to first job ≤ Sidekiq's | 0.72s vs 0.56s, 0.78s vs 0.60s | ✗ |
| ≤2 Redis commands per job | 3.00 | ✗ — deliberately: the poison-pill `DEL` was kept, [`02-fetch-ack-metrics.md`](02-fetch-ack-metrics.md) step 4, and 3 is the settled floor |
| `rake bench` gate green | worst delta −1.6% | ✓ |

**Wurk is no longer materially slower than stock Sidekiq — it is at parity on `cpu` and `io`, and still behind on `noop` and on boot.** Against the numbers `docs/benchmarks.md` currently publishes (noop 0.45×/0.49×, cpu 0.81×/0.86×, io 0.74×/0.66×) that is a large move, and it is the number the round-trip work was aiming at. It is not a "faster than Sidekiq" result. Per CLAUDE.md pillar 3 and the `f4c7d9e` policy, **no "faster" claim may be added to the README, site, or llms.txt.** `noop` — pure framework overhead — is exactly where 3 commands per job against Sidekiq's 1 still costs, and it is the shape that has to cross 1.0× before that changes.

## 6. Reproducing

```bash
bin/rake bench                                        # gate; feed 3 runs per side to bin/bench-compare
bin/rake bench:vs_sidekiq                             # 1p × 5t
WURK_BENCH_VS_PROCESSES=4 bin/rake bench:vs_sidekiq   # 4p × 5t
bin/rake bench:command_count                          # commands/job
```

`WURK_BENCH_VS_RUNS=12` reproduces the sample size above in a single invocation. On a loaded machine, prefer several separate invocations and pair the runs — a single median of 3 is not stable enough to publish from.
