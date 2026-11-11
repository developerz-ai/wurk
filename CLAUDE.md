# CLAUDE.md

Guidance for agents in this repository. **Budget: under 12,000 chars** — the developerz.ai in-cluster loader keeps only the first 12,000 (`test/unit/ai_config_test.rb` holds the line). Move detail down, never raise the cap:

| Touching | Also read (auto-loads there) |
|---|---|
| `lib/`, `app/`, `exe/` | [`lib/CLAUDE.md`](lib/CLAUDE.md): who owns what, layer by layer |
| `test/` | [`test/CLAUDE.md`](test/CLAUDE.md): runner, Redis isolation, layers, coverage |
| `.github/`, `RELEASE.md`, `lib/wurk/version.rb` | [`.github/CLAUDE.md`](.github/CLAUDE.md): CI standard, bench, release lane |
| `frontend/` | [`frontend/CLAUDE.md`](frontend/CLAUDE.md): dashboard stack and styles |

`AGENTS.md` is a symlink to this file.

## Wurk

100% API-compatible drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise. Free. Fork-based swarm for multi-core parallelism. Mountable Rails engine.

Three pillars, all must stay true:

1. **100% drop-in.** Same Redis key schema, same job JSON, same Ruby DSL. Existing Sidekiq jobs and Redis data keep working on a one-line gem swap. sidekiq-cron, sidekiq-unique-jobs, sidekiq-failures and sentry-sidekiq pass their own test suite against Wurk (exclusions per `test/ecosystem/README.md`); the rest (sidekiq-scheduler, sidekiq-status, sidekiq-throttled) are tracked in `docs/idea/14-ecosystem-compat.md`.
2. **Free.** Pro + Ent feature parity in the same gem. No tiers, no flags gating Ent behavior, no license checks.
3. **Measured.** Two suites, different jobs. `rake bench` is the REGRESSION check (wurk vs its own past self; a regression beyond both runs' error bounds plus 5% is flagged on the PR — advisory, see `.github/CLAUDE.md`). `rake bench:vs_sidekiq` is the COMPARISON vs stock Sidekiq. A green bench says nothing about Sidekiq. The latest published comparison has Wurk SLOWER than stock Sidekiq (0.87x–1.02x depending on workload, parity on CPU/IO, behind on noop and boot; `docs/benchmarks.md`) — do not add a "faster" claim to the README, site, or llms.txt until that doc's numbers support it.

## Never

- Change Redis key schema or job JSON format.
- Use MessagePack or any non-JSON job format.
- Mock Redis in integration or parity tests.
- Add a license check, paid tier, or env flag that gates an Ent feature.
- Add backwards-compat shims, dead-code comments, or speculative abstractions. Three duplicate lines beats the wrong abstraction.
- `--no-verify` on commits when hooks fail — fix the hook.
- Share a Redis socket across forks.
- Force-push to `main`.
- Use git worktrees. Work in this checkout; parallel agents split into disjoint file sets.
- Touch Redis DB 0, or run `FLUSHALL` or `SCRIPT FLUSH`, from a test or harness. Local DB 0 is someone's data, and those two cross logical DBs. Use `WURK_TEST_DB_OFFSET` or a private port.
- Merge a breaking change without a human decision.

## Commands

| Task | Command |
|---|---|
| Install | `bin/setup` (gems, frontend, dummy app). Tests need Redis ≥ 7 and bun |
| Private Redis | `eval "$(bin/redis env [name])"`: own server per agent, never :6379 |
| Pre-PR gate | `bin/check`: rubocop + frontend + suite with coverage + parity. `fast` = rubocop + anchors + unit. `full` = + ecosystem + Python client. `SKIP_LINT=1` / `SKIP_PARITY=1` / `SKIP_FRONTEND=1` drop a stage, `NCPU=<n>` sets workers. **Exit 75 = environment missing (bundler, gems, Redis, bun), not a verdict on the diff** |
| Suite (unit + integration + engine) | `bin/rake test` |
| Single file | `bin/rake test TEST=test/path/to/file_test.rb` (several: comma-separated) |
| Single test by name | `bin/rake test TEST=test/foo_test.rb TESTOPTS="--name=/pattern/"` |
| Parity + conformance oracles | `bin/rake test:parity` |
| Ecosystem compat | `bin/rake test:ecosystem` (own throwaway `redis-server`) |
| Re-pin ledger anchors | `bin/repin-anchors` (`--check` reports only) |
| Benchmarks | `bin/rake bench`, `bin/rake bench:vs_sidekiq` |
| Dashboard + dummy app | `bin/dev`, then http://localhost:3000/wurk (Redis + Vite HMR + `test/dummy`; `NO_VITE=1` serves the prebuilt bundle) |
| Runners | `exe/wurk` (one process), `exe/wurkswarm` (forks `WURK_COUNT`), `exe/wurk api` (HTTP API, runs no jobs) |
| Ops, read-only | `wurk preflight` (before a cutover), `wurk verify` (after one), `wurk health` (exec liveness probe) |
| Dashboard build | `bin/rake frontend:build` |
| Dashboard checks, in `frontend/` | `bun run test`, `bun run lint`, `bun run typecheck` |
| Release | Merge a `lib/wurk/version.rb` bump to `main` (`RELEASE.md`; `bin/rake release` aborts) |

The railtie boots workers only inside a running web server or with `WURK_EMBED=1`. `WURK_DISABLED=1`, Rails console, Rails test env, rake tasks and `SECRET_KEY_BASE_DUMMY` all skip it; a preforking server (Puma cluster, Unicorn, Passenger) refuses unless `config.wurk.embed_in_web` (`lib/wurk/rails_boot.rb`).

## Architecture

Layers and ownership — one reason to change per class. Don't blur these. Hot path, full table in `lib/CLAUDE.md`:

Swarm (parent; forks, supervises) → Launcher (per worker process) → Manager (one per Capsule; thread pool, lifecycle) → Processor (takes a UnitOfWork from the Fetcher, parses, runs middleware + perform, ACKs). Fetcher owns the Redis pop. Client owns enqueue. Heartbeat is Launcher's, not Manager's.

User-facing code (mount, controllers, views, generators, assets) lives in the engine. Non-user-facing (swarm, fetcher, processor, client, middleware) lives in plain Ruby under `lib/`. **Standalone mode must run without loading the engine.**

Sidekiq aliases — every `Wurk::*` class with an upstream Sidekiq counterpart is exposed under its `Sidekiq::*` name (`Sidekiq::Worker`, `Sidekiq::Batch`, `Sidekiq.configure_server`, `Sidekiq::Limiter`, …; `lib/wurk/compat.rb` is the list). The alias is the drop-in contract. Never break it. Deliberately not aliased: `Sidekiq::Cron` and `Sidekiq::Status`, namespaces third-party gems own (#204). Wurk-only extras and internals (`Wurk::API`, `Wurk::Swarm`, `Wurk::Topology`) get no alias unless nothing else claims the name; check before adding one.

## Boot ordering (do not reorder)

1. Host app boots fully; initializers run; eager-loaded constants resolved.
2. Host `after_initialize` hooks run, then the railtie's `wurk_boot` Finisher initializer fires last (`wurkswarm`: `CLI#run_swarm` boots the app itself).
3. Swarm closes parent-side connections that must not survive fork (DB, Redis).
4. Swarm forks N children.
5. Each child opens a fresh Redis pool (Active Record reconnects through its own fork hook), then starts fetching.
6. Parent enters supervision loop (on a background thread when co-hosted in a Rails server).

Skip step 3 → leaked sockets in children. Skip step 5 → children corrupt each other's responses on a shared socket.

## Signals

For a swarm that owns its traps (`wurkswarm`). A swarm co-hosted in a Rails server boots with `install_signals: false`: the host keeps every signal and the swarm drains from `at_exit`, so TSTP and USR1 do not reach it.

| Signal | Target | Effect |
|---|---|---|
| SIGTERM / SIGINT | parent | Graceful drain. Relayed to children; in-flight finishes to `shutdown_timeout`; exit |
| SIGTSTP | parent | Quiet globally: relayed to children, each stops fetching; in-flight continues. One-way (matches Sidekiq TSTP, spec §21.3) — no resume; TERM to shut down |
| SIGUSR1 | parent | Rolling restart: fork replacement → wait for heartbeat → SIGTERM old slot → next |
| SIGUSR2 | parent, child | Reopen log files (logrotate); the parent relays |
| SIGTTIN | parent, child | Dump thread backtraces; the parent relays |
| SIGKILL | any | Safe — private-list entries stay in Redis and are reclaimed once the owner's heartbeat expires: about 1s for a swarm child, 90s after a pod restart, 90-140s for a lost host (`docs/deployment.md`) |

## Conventions

- **SOLID, especially SRP.** Manager owns lifecycle; Fetcher owns Redis pop; Processor owns middleware+perform; Client owns enqueue.
- **Wire-compat is sacred.** Never change a Redis key, JSON field, or sorted-set score format. If a perf optimization would break compat, drop the optimization.
- **Frozen string literals everywhere.** Hot-loop allocations matter.
- **Per-fork Redis pool.** Never share a socket across forks. Close parent sockets before fork, reconnect inside the child.
- **Parse the payload once, carry the raw string.** `Processor` parses the job JSON a single time, then threads the original string through the retry and stats layers so nothing re-dumps it; the retriers re-parse only on the failure path.
- **EVALSHA-cache Lua scripts.** Loaded once per pool; re-uploaded only on `NOSCRIPT` recovery.
- **Default fetcher is reliable.** Atomic move from main queue to per-process private list: `LMOVE` while there is work, `BLMOVE` to park on an empty poll. No "basic fetch" mode.
- **Authoritative spec** for any Sidekiq surface lives in `docs/target/sidekiq-{free,pro,ent}.md`. Match it exactly when implementing or modifying public API.
- **No comments that restate code.** Only document non-obvious *why*: a hidden constraint, a workaround for a specific bug, behavior that would surprise a reader.

## Testing

Minitest, real Redis. Parity tests are oracles: when Wurk diverges from one, Wurk is wrong unless the divergence is documented as intentional in [`docs/idea/parity-divergences.md`](docs/idea/parity-divergences.md). SimpleCov line and branch coverage on `lib/` must both stay ≥90%. The `main-protection` ruleset's live required checks are the single authority: `gh api repos/developerz-ai/wurk/rulesets`; never re-declare the list.

## Rules from incidents

- **The merge bot merges on green.** Soak and review come before the push, not after.
- **A merge does not deploy.** Only a merged `lib/wurk/version.rb` bump publishes. `release: x.y.z` and nothing else, with `bundle exec rake release:relock_demo`. Never tag, never `gem push` (#420, #858). Then verify directly: the gem on RubyGems, the tag, the demo's `/demo/build`.
- **A red `compat` leg on `main` is yours to fix**, though it never blocks a merge. Rubocop's `TargetRubyVersion` catches syntax, not runtime behavior, and local runs use a newer Ruby than the 3.2 floor (#823, #869).
- **`lib/` edits move line anchors.** The ledger and `test/conformance/` pin `lib/` line ranges (`bin/check` reports drift). Run `bin/repin-anchors`, on the tree the PR actually contains: anchors re-pinned on a wider tree go red once the PR is split.
- **Stage by path.** Never `git add -A`: the tree may hold someone else's work. A split PR is tested on its own tree.
- **A PR body claims only what the diff does.** Evidence you could not get is stated as missing (#823).
- **Never write live state into prose or config comments.** Cite the command that reads it (#388, #445).
- **Commit with a GitHub-linked email.** The ruleset parks a PR with unattributed commits for human approval, silently.
- **A hook refused something legitimate?** See `.claude/README.md`; never work around it.

## Platforms

Ruby `>= 3.2.0`, Redis `>= 7.0.0` (`CLI` and `Embedded` refuse older). Valkey 8 and Dragonfly >= 1.34 are `compat` legs; a Dragonfly job store must stay below `maxmemory` (`docs/deployment.md`). No CI leg runs JRuby, TruffleRuby or Windows. Without `fork`, only `exe/wurk` and `config.wurk.embed_in_web` can work; `wurkswarm` and the railtie's swarm call `Process.fork` with no fallback. The Rails test env skips the railtie's boot and changes nothing else: jobs push to real Redis unless `Sidekiq::Testing` says otherwise, and integration tests fork real swarms.
