# Contributing to Wurk

Thanks for helping make Wurk better. This guide covers local setup, the test
layers, and the conventions a change has to follow to merge.

## Setup

```sh
git clone https://github.com/developerz-ai/wurk
cd wurk
bundle install
```

You'll need a local **Redis ≥ 7.0** running (tests use real Redis, never a mock).
Node is only needed if you touch the dashboard frontend (`frontend/`); the
precompiled bundle is committed under `vendor/assets/`.

## Running the tests

| Task | Command |
|---|---|
| Full suite (parallel) | `bin/rake test` |
| A single file | `bin/rake test TEST=test/path/to/file_test.rb` |
| A single test by name | `bin/rake test TEST=test/foo_test.rb TESTOPTS="--name=/pattern/"` |
| Parity suite (oracles lifted from Sidekiq) | `bin/rake test:parity` |
| Ecosystem compatibility | `bin/rake test:ecosystem` |
| Coverage gate | `COVERAGE=1 bin/rake test` |
| Benchmarks | `bin/rake bench` |
| Lint | `bundle exec rubocop` |

Test layers:

- **unit** — plain Ruby classes in isolation.
- **engine** — boots the dummy Rails app in `test/dummy/`.
- **integration** — real forks + real Redis.
- **parity** (`test/parity/`) — tests lifted from upstream Sidekiq, SHA-pinned.
  These are **oracles**: if Wurk diverges, Wurk is wrong unless the divergence
  is explicitly documented as intentional.
- **ecosystem** — third-party Sidekiq gem suites run against Wurk.

Never mock Redis in integration or parity tests. Each test uses a unique Redis
key namespace so the parallel runner stays safe.

## Conventions

These are non-negotiable — they're what keep Wurk a true drop-in:

- **Wire-compat is sacred.** Never change a Redis key, JSON field, or
  sorted-set score format. If an optimization would break compatibility, drop
  the optimization.
- **SOLID, especially SRP.** One reason to change per class — Manager owns
  lifecycle, Fetcher owns the Redis pop, Processor owns middleware + perform,
  Client owns enqueue.
- **Match the spec.** Any public Sidekiq surface must match
  `docs/target/sidekiq-{free,pro,ent}.md` exactly.
- **Frozen string literals everywhere**; per-fork Redis pools (never share a
  socket across a fork).
- **Comments explain non-obvious _why_**, never restate the code.
- **Coverage**: line coverage on `lib/` must stay ≥ 90% (the gate blocks PRs
  below it). Branch coverage is tracked and ratcheting toward 90%.

## Pull requests

1. Branch off `main`.
2. Keep the change focused; add tests at the right layer.
3. Run `bin/rake test`, `bin/rake test:parity`, `bin/rake test:ecosystem`, and `bundle exec rubocop` locally.
4. Open the PR — CI runs the matrix (Ruby 3.2/3.3/3.4 × Rails 7.2/8.0), the
   coverage gate, the parity job, and benchmarks. The bench bot comments
   per-benchmark deltas; a real regression fails the check.
5. Don't `--no-verify` past a failing hook — fix the hook.

By contributing you agree your work is licensed under the project's
[MIT License](LICENSE).
