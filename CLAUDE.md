# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Wurk

100% API-compatible drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise. Free. Fork-based swarm for multi-core parallelism. Mountable Rails engine.

Three pillars, all must stay true:

1. **100% drop-in.** Same Redis key schema, same job JSON, same Ruby DSL. Existing Sidekiq jobs and Redis data keep working on a one-line gem swap. Third-party gems (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-status, sidekiq-failures, sidekiq-throttled, etc.) pass their own test suites against Wurk.
2. **Free.** Pro + Ent feature parity in the same gem. No tiers, no flags gating Ent behavior, no license checks.
3. **Measured.** Two suites, different jobs. `rake bench` is the REGRESSION gate (wurk vs its own past self; >5% on enqueue / fetch+execute / bulk enqueue / swarm boot / memory blocks merge). `rake bench:vs_sidekiq` is the COMPARISON vs stock Sidekiq. A green gate says nothing about Sidekiq. Wurk is currently SLOWER than stock Sidekiq (0.87x–1.02x depending on workload, with parity on CPU/IO but still behind on noop and boot, see `docs/benchmarks.md`) — do not add a "faster" claim to the README, site, or llms.txt until that doc's numbers support it.

## Commands

| Task | Command |
|---|---|
| Install | `bundle install` |
| Pre-PR gate (lint + suite + parity) | `bin/check` (`fast` = lint + unit, `full` = + ecosystem) |
| Full test suite (parallel) | `bin/rake test` |
| Single file | `bin/rake test TEST=test/path/to/file_test.rb` |
| Single test by name | `bin/rake test TEST=test/foo_test.rb TESTOPTS="--name=/pattern/"` |
| Parity tests (lifted from Sidekiq) | `bin/rake test:parity` |
| Ecosystem compat | `bin/rake test:ecosystem` |
| Benchmarks | `bin/rake bench` |
| Dummy app | `cd test/dummy && bin/rails s` |
| Standalone runner | `exe/wurk` |
| Dashboard build | `bin/rake frontend:build` (`bun install` + `vite build` → `vendor/assets/`) |
| Dashboard tests | `bun run test` in `frontend/` (vitest) |
| Dashboard lint | `bun run lint` in `frontend/` (oxlint, not eslint — typescript-eslint can't parse TS 7) |
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
| Web | Rack app serving the precompiled SolidJS SPA + JSON APIs | `lib/wurk/web.rb`, `app/` |
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
| SIGTSTP | parent | Quiet globally: relayed to children, each stops fetching; in-flight continues. One-way (matches Sidekiq TSTP, spec §21.3) — no resume; TERM to shut down |
| SIGUSR1 | parent | Rolling restart: fork replacement → wait for heartbeat → SIGTERM old slot → next |
| SIGUSR2 | child | Reopen log files (logrotate) |
| SIGKILL | any | Safe — private-list entries stay in Redis and are reclaimed on next boot |

## Conventions

- **SOLID, especially SRP.** Manager owns lifecycle; Fetcher owns Redis pop; Processor owns middleware+perform; Client owns enqueue.
- **Wire-compat is sacred.** Never change a Redis key, JSON field, or sorted-set score format. If a perf optimization would break compat, drop the optimization.
- **Frozen string literals everywhere.** Hot-loop allocations matter.
- **Per-fork Redis pool.** Never share a socket across forks. Close parent sockets before fork, reconnect inside the child.
- **Parse the payload once, carry the raw string.** `Processor` parses the job JSON a single time, then threads the original string through the retry and stats layers so nothing re-dumps it; the retriers re-parse only on the failure path.
- **EVALSHA-cache Lua scripts.** Loaded once per pool, never re-uploaded.
- **Default fetcher is reliable.** BLMOVE atomic move from main queue to per-process private list. No "basic fetch" mode.
- **Authoritative spec** for any Sidekiq surface lives in `docs/target/sidekiq-{free,pro,ent}.md`. Match it exactly when implementing or modifying public API.
- **No comments that restate code.** Only document non-obvious *why*: a hidden constraint, a workaround for a specific bug, behavior that would surprise a reader.

## Testing

- **Minitest**, parallel runner. Each class opts in via `parallelize_me!`.
- **Per-worker Redis DB isolation.** Each `minitest-parallel_fork` worker runs against its own Redis logical DB (1–15; never DB 0), assigned in `test_helper`'s `after_parallel_fork` hook; `teardown` runs `FLUSHDB` so each test gets a clean slate. Tests that build a pool explicitly use `Wurk::Test.redis_url`. Required for parallel safety — concurrent test classes never see each other's keys.
- **Layers:** unit · engine (boots `test/dummy/`) · integration (real forks + real Redis) · parity (`test/parity/`, lifted from Sidekiq, SHA-pinned) · ecosystem (third-party gem suites run against Wurk) · benchmarks.
- **Parity tests are oracles.** When Wurk diverges from a parity test, Wurk is wrong unless the divergence is explicitly documented as intentional.
- **Never mock Redis** in integration or parity tests. Real Redis, unique namespace.
- **Coverage gate.** SimpleCov **line** and **branch** coverage on `lib/` must both stay ≥90% (blocking; `minimum_coverage line: 90, branch: 90`). Branch was ratcheted from ~78% to ≥90% in #67 — keep new code at parity. The Cobertura report is still uploaded for per-file inspection. Coverage runs merge across the `minitest-parallel_fork` workers via `SimpleCov.at_fork`.
- **CI** on GitHub Actions. Benchmark bot comments deltas on every PR; >5% regression flags it.
- **CI standard.** Cheap by construction: **one** full Ruby suite run per PR, on the newest Ruby + newest Rails, with the coverage gate folded into it (`COVERAGE=1` on the same invocation). No version matrix and no second coverage job — the gemspec's `>= 3.2` floor is held by rubocop's `TargetRubyVersion: 3.2`. Suite workers stay at `NCPU=4` (test_helper's default, deliberately below core count — the integration layer boots real swarms, so one worker per core oversubscribes and produces wall-clock failures, measured), which is why the suite runner wants roughly a 4 vCPU box. Runner selection is a **repository variable**, not a hard-coded label: `vars.WURK_CI_RUNNER` for detect/suite/parity/lint/frontend and ecosystem, `vars.WURK_BENCH_RUNNER` for bench. Both fall through to `ubuntu-latest` when unset, and a fork PR is pinned to `ubuntu-latest` unconditionally — wurk is public, a fork PR runs attacker-authored code, and that must never reach self-hosted hardware. Pointing CI at different hardware, or rolling back, is therefore a settings change rather than a PR. `release.yml` and both dependabot workflows stay on `ubuntu-latest` outright, keeping the RubyGems publish credential on a VM that is destroyed after the job. **Bench no longer sits on a fixed 8vcpu SKU** — `rake bench` gates merge at >5% (pillar 3), so its variance band is what to watch when that variable is pointed at new hardware; developerz-ai/infrastructure#1259 tracks the measurement and the one-variable rollback. Note that no static check catches a typo'd runner variable: an unknown name resolves to empty and yields green CI identical to the intended fallback, so verify the expression sites by grep, not by a green run. Every workflow declares a `concurrency` group with cancel-in-progress, and every job sets `timeout-minutes`. Deploy/publish workflows (deploy-demo, pages, release) never auto-cancel: `cancel-in-progress: false`.
- **The release tag is an output, never an input.** `release.yml` fires on a `lib/wurk/version.rb` bump landing on `main` — *not* on a tag push — derives the tag from `Wurk::VERSION` (`ReleaseHelpers.git_tag_for`), publishes the gem, and only then cuts the tag + GitHub Release, which then calls `deploy-demo` so the public demo tracks the released version. Never re-add a `tags:` trigger: a tag as input let anything that could push one (the `developerz-ai[bot]` maintainer agent did, seven times) turn the release lane red and leave a gem-less GitHub Release marked "Latest". Full rationale in `RELEASE.md`.

## Platforms

Ruby `>= 3.2.0`, Redis `>= 7.0.0`. JRuby / TruffleRuby / Windows fall back to threads-only mode (no fork), behaviorally equivalent to stock Sidekiq. Test env disables forking — everything runs inline.

## Dashboard

SolidJS + TypeScript + Vite SPA mounted under the engine, built with **bun** (`bun install` + `vite build`; contributors need bun, consumers never run Node or bun). **Precompiled bundle ships in the gem** (`vendor/assets/`). SSE for live updates, TanStack Query (`@tanstack/solid-query`) for state, `@solidjs/router` for routing, and a hand-rolled dependency-free SolidJS SVG chart module for charts. Pages are **lazy-loaded behind a route-level `<Suspense>`** (code-split chunks) with **skeleton loaders** (`components/Skeleton.tsx`) as the fallback. Left-rail nav (drawer on mobile), dark by default with an opt-in light theme (`light`/`dark`/`system`, `config.web.default_theme`, no light-toggle performance cost), mobile-first, i18n with host-app override. AI panes (anomaly detection, NL queries, error triage, capacity advisor) are opt-in and require an Anthropic API token.

**Styles** are a SOLID/SRP **SCSS** architecture under `frontend/src/styles/` — `abstracts/` (Sass maps, `to-rem()`/`breakpoint()`/`z()` functions, `respond-down()`/`transition()`/`surface()` mixins, CSS-var `:root` tokens, keyframes) → `base/` (reset, typography, scrollbar, reduced-motion policy) → `components/` (one file per atom: button, badge, card, table, modal, skeleton…) → `layout/` (shell, nav, page-header) → `pages/` (dashboard hero, Obsidian system, search, extension), composed by `main.scss`. Tailwind + daisyUI directives stay in the sibling `tailwind.css`; the SCSS `:root` tokens (unlayered) override daisyUI's theme. All lengths are `to-rem()`; motion runs off a shared duration/easing scale (`--dur-*` / `--ease-*`). `rem` is a reserved Sass calc name — the px→rem helper is `to-rem()`, not `rem()`.

## Never

- Change Redis key schema or job JSON format.
- Use MessagePack or any non-JSON job format.
- Mock Redis in integration or parity tests.
- Add a license check, paid tier, or env flag that gates an Ent feature.
- Add backwards-compat shims, dead-code comments, or speculative abstractions. Three duplicate lines beats the wrong abstraction.
- `--no-verify` on commits when hooks fail — fix the hook.
- Share a Redis socket across forks.
- Force-push to `main`.

## Note

Do not use git worktrees — work directly in this checkout. If a task is big enough to need subagents, run them as a team in this same checkout: split the work into disjoint pieces so no two agents touch the same files.
