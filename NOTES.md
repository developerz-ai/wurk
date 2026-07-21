# wurk

Wurk is a 100% API-compatible, free drop-in replacement for Sidekiq, including the Pro and
Enterprise feature set, packaged as a Ruby gem and mountable Rails engine. It keeps the same
Redis key schema, job JSON and Ruby DSL so an existing app switches with a one-line gem swap
and third-party Sidekiq gems keep passing their own suites. Its differentiator is speed: a
fork-based swarm gives real parallelism, and every release is benchmarked against stock Sidekiq.

- **Stack:** Ruby gem (Rails engine + standalone runner), Redis via redis-client, Lua scripts
  for bulk paths; dashboard is a SolidJS SPA built with Vite/Bun and vendored into
  `vendor/assets/`; Minitest for tests, RuboCop for lint; released to RubyGems.
- **Key commands:**
  - `bundle install`
  - `bin/rake test` — full parallel suite (`TEST=` / `TESTOPTS=` to narrow)
  - `bin/rake test:parity` — tests lifted from Sidekiq; `bin/rake test:ecosystem` — gem compat
  - `bin/rake bench` — benchmarks vs Sidekiq
  - `bin/rake frontend:build` — build the dashboard; `bin/rake release` — build + push the gem
- **Layout:**
  - `lib/wurk/` — swarm, manager, fetcher, processor, client, middleware, redis pool, engine
  - `app/` — engine-side dashboard controllers/views and mounted assets
  - `frontend/` — SolidJS dashboard source (vitest); output vendored into `vendor/assets/`
  - `test/` — unit, parity and ecosystem suites plus `test/dummy` Rails app
  - `docs/target/` — authoritative Sidekiq free/pro/ent specs to implement against
  - `bench/`, `examples/`, `demo/`, `ecosystem/` — benchmarks and compatibility harnesses
- **State as of 2026-07-21:** branch `main`; working tree was clean when this note was written.
