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

## CI: GitHub Actions on Blacksmith runners

Blacksmith (https://blacksmith.sh) provides faster runners than stock ubuntu-latest with better caching. We use Blacksmith for:

- Test matrix (Ruby × Redis × Rails versions)
- Ecosystem compat suite
- Benchmark suite
- Docs site build

The test workflow runs the matrix on a 4-vCPU Blacksmith runner. Each matrix cell:

- Checks out the repo.
- Sets up Ruby via Blacksmith's setup action with bundler cache.
- Boots Redis and Postgres service containers.
- Runs the dummy app setup.
- Runs the full Minitest suite in parallel mode.

Benchmark job runs on an 8-vCPU Blacksmith runner and uploads results as artifacts. A bot comments deltas vs main on every PR. Regressions greater than 5% flag the PR.

## Coverage

SimpleCov with branch coverage. CI fails when branch coverage on the gem's main lib tree drops below 90%.

## Release gate

Before a tag is cut:

- Full matrix green.
- Ecosystem compat matrix green.
- Benchmark suite reports no regressions vs the previous tag.
- Precompiled assets bundle is fresh.
- Parity test SHA pin matches the latest Sidekiq main we've reviewed.
