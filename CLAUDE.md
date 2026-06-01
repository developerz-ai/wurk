# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Wurk

100% API-compatible drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise. Free. Faster via fork-based real parallelism. Mountable Rails engine.

Three pillars, all must stay true:

1. **100% drop-in.** Same Redis key schema, same job JSON, same Ruby DSL. Existing Sidekiq jobs and Redis data keep working on a one-line gem swap. Third-party gems (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-status, sidekiq-failures, sidekiq-throttled, etc.) pass their own test suites against Wurk.
2. **Free.** Pro + Ent feature parity in the same gem. No tiers, no flags gating Ent behavior, no license checks.
3. **Faster.** Every release benchmarked vs stock Sidekiq. >5% regression on enqueue / fetch+execute / bulk enqueue / swarm boot / memory blocks merge.

## Commands

| Task | Command |
|---|---|
| Install | `bundle install` |
| Full test suite (parallel) | `bin/rake test` |
| Single file | `bin/rake test TEST=test/path/to/file_test.rb` |
| Single test by name | `bin/rake test TEST=test/foo_test.rb TESTOPTS="--name=/pattern/"` |
| Parity tests (lifted from Sidekiq) | `bin/rake test:parity` |
| Ecosystem compat | `bin/rake test:ecosystem` |
| Benchmarks | `bin/rake bench` |
| Dummy app | `cd test/dummy && bin/rails s` |
| Standalone runner | `exe/wurk` |
| Dashboard HMR dev | `WURK_VITE_DEV=1` then boot dummy |
| Release | `bin/rake release` (Vite build → `vendor/assets/` → gem build → push) |

`WURK_DISABLED=1`, Rails console, and Rails test env all skip the railtie's auto-fork.

## Architecture

Layers and ownership — one reason to change per class. Don't blur these.

| Layer | Owns | Path |
|---|---|---|
| Engine | Dashboard mount, asset path, railtie | `lib/wurk/engine.rb`, `app/` |
| Railtie | `after_initialize` hook that starts the swarm | `lib/wurk/railtie.rb` |
| Swarm | Parent process; forks N children, PID supervision, rolling restart | `lib/wurk/swarm.rb` |
| Manager | Inside each child: thread pool, lifecycle, heartbeat | `lib/wurk/manager.rb` |
| Fetcher | BLMOVE reliable fetch: main queue → per-process private list | `lib/wurk/fetcher.rb` |
| Processor | Pops private list, runs middleware chain, invokes perform | `lib/wurk/processor.rb` |
| Client | Enqueue, Lua bulk path, Redis-outage local buffer | `lib/wurk/client.rb` |
| Middleware | Client + server chains (Sidekiq contract) | `lib/wurk/middleware/` |
| Web | Rack app serving the precompiled React SPA + JSON APIs | `lib/wurk/web.rb`, `app/` |
| RedisPool | Per-process pool over redis-client | `lib/wurk/redis_pool.rb` |

User-facing code (mount, controllers, views, generators, assets) lives in the engine. Non-user-facing (swarm, fetcher, processor, client, middleware) lives in plain Ruby under `lib/`. **Standalone mode must run without loading the engine.**

Sidekiq aliases — every public `Wurk::*` class is exposed under its `Sidekiq::*` name (`Sidekiq::Worker`, `Sidekiq::Batch`, `Sidekiq.configure_server`, `Sidekiq::Limiter`, …). The alias is the drop-in contract. Never break it.

## Boot ordering (do not reorder)

1. Host app boots fully; initializers run; eager-loaded constants resolved.
2. Railtie `after_initialize` fires.
3. Swarm closes parent-side connections that must not survive fork (DB, Redis).
4. Swarm forks N children.
5. Each child reconnects DB and opens a fresh Redis pool, then starts fetching.
6. Parent enters supervision loop.

Skip step 3 → leaked sockets in children. Skip step 5 → children corrupt each other's responses on a shared socket.

## Signals

| Signal | Target | Effect |
|---|---|---|
| SIGTERM / SIGINT | parent | Graceful drain. Relayed to children; in-flight finishes to `shutdown_timeout`; exit |
| SIGTSTP | parent | Pause fetch globally; in-flight continues; SIGCONT resumes |
| SIGUSR1 | parent | Rolling restart: fork replacement → wait for heartbeat → SIGTERM old slot → next |
| SIGUSR2 | child | Reopen log files (logrotate) |
| SIGKILL | any | Safe — private-list entries stay in Redis and are reclaimed on next boot |

## Conventions

- **SOLID, especially SRP.** Manager owns lifecycle; Fetcher owns Redis pop; Processor owns middleware+perform; Client owns enqueue.
- **Wire-compat is sacred.** Never change a Redis key, JSON field, or sorted-set score format. If a perf optimization would break compat, drop the optimization.
- **Frozen string literals everywhere.** Hot-loop allocations matter.
- **Per-fork Redis pool.** Never share a socket across forks. Close parent sockets before fork, reconnect inside the child.
- **Lazy `JSON.parse` of args.** Only deserialize when middleware demands it.
- **EVALSHA-cache Lua scripts.** Loaded once per pool, never re-uploaded.
- **Default fetcher is reliable.** BLMOVE atomic move from main queue to per-process private list. No "basic fetch" mode.
- **Authoritative spec** for any Sidekiq surface lives in `docs/target/sidekiq-{free,pro,ent}.md`. Match it exactly when implementing or modifying public API.
- **No comments that restate code.** Only document non-obvious *why*: a hidden constraint, a workaround for a specific bug, behavior that would surprise a reader.

## Testing

- **Minitest**, parallel runner. Each class opts in via `parallelize_me!`.
- **Per-test Redis namespace** keyed to `PID:object_id`; cleaned in teardown. Required for parallel safety.
- **Layers:** unit · engine (boots `test/dummy/`) · integration (real forks + real Redis) · parity (`test/parity/`, lifted from Sidekiq, SHA-pinned) · ecosystem (third-party gem suites run against Wurk) · benchmarks.
- **Parity tests are oracles.** When Wurk diverges from a parity test, Wurk is wrong unless the divergence is explicitly documented as intentional.
- **Never mock Redis** in integration or parity tests. Real Redis, unique namespace.
- **Coverage gate.** SimpleCov **line** coverage on `lib/` must stay ≥90% (blocking). Branch coverage is also measured and uploaded but not yet gated (currently ~78%, ratcheting toward 90% — see #29). Coverage runs merge across the `minitest-parallel_fork` workers via `SimpleCov.at_fork`.
- **CI** on GitHub Actions / Blacksmith runners. Benchmark bot comments deltas on every PR; >5% regression flags it.

## Platforms

Ruby `>= 3.2.0`, Redis `>= 7.0.0`. JRuby / TruffleRuby / Windows fall back to threads-only mode (no fork), behaviorally equivalent to stock Sidekiq. Test env disables forking — everything runs inline.

## Dashboard

React + TypeScript + Vite SPA mounted under the engine. **Precompiled bundle ships in the gem** (`vendor/assets/`); consumers never run Node. SSE for live updates, TanStack Query for state, Recharts for charts, CSS variables for theming. Right-side nav, dark default, mobile-first, i18n with host-app override. AI panes (anomaly detection, NL queries, error triage, capacity advisor) are opt-in and require an Anthropic API token.

## Never

- Change Redis key schema or job JSON format.
- Use MessagePack or any non-JSON job format.
- Mock Redis in integration or parity tests.
- Add a license check, paid tier, or env flag that gates an Ent feature.
- Add backwards-compat shims, dead-code comments, or speculative abstractions. Three duplicate lines beats the wrong abstraction.
- `--no-verify` on commits when hooks fail — fix the hook.
- Share a Redis socket across forks.
- Force-push to `main`.
