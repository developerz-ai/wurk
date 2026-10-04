# Testing & CI

## Framework: Minitest

Reasons:

- Sidekiq itself uses Minitest. Easier to lift its tests as parity oracles.
- Minitest's parallel runner is built in and trivial to enable.
- Smaller dependency footprint than RSpec.

## Parallel execution (multi-CPU)

Minitest's parallel executor forks `NCPU` workers, which `test_helper` defaults to half the cores, floored at 1 and capped at 4 (`Wurk::Test::DEFAULT_NCPU`) — deliberately below core count, because the integration layer boots real swarms and one worker per core oversubscribes into wall-clock failures. `NCPU` is the knob for a box with headroom. Each test class opts in via `parallelize_me!`. Per-worker Redis DB isolation prevents cross-test interference — each worker owns a logical DB and `teardown` runs `FLUSHDB`.

Tests that exercise the swarm itself fork real processes and need a Redis DB per worker. CI runs one Redis service container and hands each worker its own logical DB (1-14, with 15 reserved for fixed-DB tests; never DB 0), assigned in `test_helper`'s `after_parallel_fork` hook — which is also why `NCPU` is capped at 14.

## Test layers

| Layer | What it tests |
|---|---|
| Unit | Individual modules — worker, client, fetcher, middleware, etc. |
| Engine | Dashboard routes, controllers, JSON APIs — run through the dummy Rails app (see 10-dummy-app.md) |
| Integration | End-to-end: real forks, real Redis, real perform |
| Parity | Ported tests from upstream Sidekiq's own test suite |
| Ecosystem | Real third-party Sidekiq gems' test suites, run against Wurk (see 14-ecosystem-compat.md) |
| Benchmarks | Throughput, latency, memory — must not regress vs the PR's base |

## Sidekiq parity tests

The parity oracles under `test/parity/` are independently written against the documented Sidekiq behaviour — they are not copies of upstream test files (Sidekiq is LGPL-3.0, this repo is MIT). A pin file at `test/parity/.sidekiq_sha` records the upstream Sidekiq revision the oracles target.

## Ecosystem gem tests

A dedicated CI job runs the test suites of widely-used Sidekiq ecosystem gems against Wurk. Today that is sidekiq-cron only; the other targets (sidekiq-unique-jobs, sidekiq-scheduler, …) and their blockers are in `14-ecosystem-compat.md`. These are the strongest possible drop-in proof.

## CI: GitHub Actions

Every job runs on GitHub-hosted `ubuntu-latest` (free for a public repo). There are no self-hosted runners and no runner variables, so a fork PR never reaches persistent hardware; outside contributors' runs still wait on the repo's approval policy. In test.yml and ecosystem.yml the `detect` job runs `bin/ci-dup-push`: a push to `main` whose tree byte-equals a PR head that already passed the workflow skips the gated jobs, and any doubt falls open to a full run. PR runs cancel in progress; `main` runs never do. The headline suites:

- Test suite (one full run on the newest Ruby + newest Rails, coverage gate folded in — no version matrix)
- Ecosystem compat suite
- Benchmark suite
- Docs site build (pages.yml, `ubuntu-latest`)

The test workflow's suite job:

- Checks out the repo.
- Sets up Ruby via `ruby/setup-ruby` with bundler cache.
- Boots a Redis service container and resolves its mapped port.
- Sets up bun and builds the dashboard SPA into `vendor/assets/`.
- Runs the dummy app setup.
- Runs the full Minitest suite in parallel mode, with the coverage gate folded into the same invocation (`COVERAGE=1`).

The benchmark job runs on `ubuntu-latest` and publishes the delta vs the PR's base to the job summary and a sticky PR comment, on PRs that touch a bench input (`lib/`, `exe/`, `bench/`, `bin/bench-compare`, the Rakefile, Gemfile/gemspec, or the workflow itself). Regressions past the threshold flag the PR in that comment; bench is not a required check, and hosted-runner noise is why.

## Coverage

SimpleCov with branch coverage. CI fails when branch coverage on the gem's main lib tree drops below 90%.

## Release gate

Before a tag is cut:

- Test suite green.
- Ecosystem compat suite green.
- Benchmark deltas reviewed on the PRs that landed since the last tag. There is no tag-time bench run: `bench.yml` is `on: pull_request` and compares the PR's base, and `rake release:check` never invokes bench.
- Precompiled assets bundle is fresh.
- Parity test SHA pin matches the latest Sidekiq main we've reviewed.
