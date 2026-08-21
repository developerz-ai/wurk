# Testing & CI

## Framework: Minitest

Reasons:

- Sidekiq itself uses Minitest. Easier to lift its tests as parity oracles.
- Minitest's parallel runner is built in and trivial to enable.
- Smaller dependency footprint than RSpec.

## Parallel execution (multi-CPU)

Minitest's parallel executor uses all available CPU cores. Each test class opts in via `parallelize_me!`. Per-test Redis namespace isolation prevents cross-test interference — each test gets a unique key prefix tied to PID plus object id, cleaned up in teardown.

Tests that exercise the swarm itself fork real processes and need a Redis DB per worker. CI provisions enough Redis DBs (or separate Redis containers) for the parallel worker count.

## Test layers

| Layer | What it tests |
|---|---|
| Unit | Individual modules — worker, client, fetcher, middleware, etc. |
| Engine | Dashboard routes, controllers, JSON APIs — run through the dummy Rails app (see 10-dummy-app.md) |
| Integration | End-to-end: real forks, real Redis, real perform |
| Parity | Ported tests from upstream Sidekiq's own test suite |
| Ecosystem | Real third-party Sidekiq gems' test suites, run against Wurk (see 14-ecosystem-compat.md) |
| Benchmarks | Throughput, latency, memory — must not regress vs main |

## Sidekiq parity tests

For each public class we implement, the equivalent test from upstream Sidekiq is ported and adapted. The ported tests live under `test/parity/`. A pin file records the upstream Sidekiq SHA the parity tests were lifted from.

## Ecosystem gem tests

A dedicated CI job runs the test suites of widely-used Sidekiq ecosystem gems (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, etc.) against Wurk. See `14-ecosystem-compat.md`. These are the strongest possible drop-in proof.

## CI: GitHub Actions

Runner selection is a repository variable, not a hard-coded label: `vars.WURK_CI_RUNNER` for the detect, test, parity, lint, frontend, and ecosystem jobs, `vars.WURK_BENCH_RUNNER` for the benchmark job. Both fall through to stock `ubuntu-latest` when unset, and fork PRs are pinned to `ubuntu-latest` unconditionally. Release, pages, and dependabot workflows stay on `ubuntu-latest` by design (credential containment). CI runs:

- Test suite (one full run on the newest Ruby + newest Rails, coverage gate folded in — no version matrix)
- Ecosystem compat suite
- Benchmark suite
- Docs site build (pages.yml, `ubuntu-latest`)

The test workflow's suite job:

- Checks out the repo.
- Sets up Ruby via `ruby/setup-ruby` with bundler cache.
- Boots a Redis service container.
- Runs the dummy app setup.
- Runs the full Minitest suite in parallel mode.

The benchmark job runs wherever `vars.WURK_BENCH_RUNNER` points and publishes the delta vs main to the job summary and a sticky PR comment, on PRs that touch a bench input (`lib/`, `exe/`, `bench/`, `bin/bench-compare`, the Rakefile, Gemfile/gemspec, or the workflow itself). Regressions greater than 5% flag the PR.

## Coverage

SimpleCov with branch coverage. CI fails when branch coverage on the gem's main lib tree drops below 90%.

## Release gate

Before a tag is cut:

- Test suite green.
- Ecosystem compat suite green.
- Benchmark suite reports no regressions vs the previous tag.
- Precompiled assets bundle is fresh.
- Parity test SHA pin matches the latest Sidekiq main we've reviewed.
