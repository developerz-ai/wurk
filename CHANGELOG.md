# Changelog

All notable changes to Wurk are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0.rc1] - 2026-06-02

First v1.0.0 release candidate, and the first gem published through the keyless
(OIDC trusted publishing) release pipeline.

### Added
- `Sidekiq::Testing` drop-in: `inline!` / `fake!` / `disable!` (global or block-scoped), the in-memory `Sidekiq::Queues` store, and the `Worker`/`Job` test helpers (`.jobs`, `.clear`, `.drain`, `.perform_one`, `.process_job`, `.drain_all`, `.clear_all`) + `Sidekiq::EmptyQueueError`.

### Changed
- Release workflow now publishes to RubyGems via **trusted publishing (OIDC)** — no long-lived `GEM_HOST_API_KEY` secret. On a `v*` tag it precompiles the dashboard, gates (`release:check` now also verifies the git tag matches `Wurk::VERSION` and the asset manifest is non-empty), builds the gem and asserts the dashboard bundle is *inside* the `.gem` (`release:package`), `gem push`es via the OIDC token, and cuts a GitHub Release with the matching CHANGELOG section as notes and the `.gem` attached.

## [0.0.5] - 2026-06-01

### Added
- Project logo and a tagline in the README (rendered on GitHub and the RubyGems page).

### Changed
- Slimmed the published gem to runtime files only — Ruby, the precompiled dashboard (js/css/html + asset manifest), engine config, README, and LICENSE. CHANGELOG/CONTRIBUTING/SECURITY are no longer packaged (still on GitHub via the gem's metadata links).

## [0.0.4] - 2026-06-01

### Added
- `docs/clean-room.md` — compatibility & legal basis: Wurk reimplements the Sidekiq API (clean-room, original implementation), the *Google v. Oracle* rationale, and trademark/nominative-use notes. Linked from the README.

### Changed
- Dependency refresh. GitHub Actions bumped to current majors (`checkout@v6`, `setup-node@v6`, `upload-artifact@v7`) on Node 24, clearing the Node 20 deprecation. Dashboard frontend upgraded to React 19, React Router 7, Recharts 3, Vite 8, and TypeScript 6. Ruby dev/test gems refreshed to latest.

## [0.0.3] - 2026-06-01

### Changed
- Gem contact email set to `admin@developerz.ai`.

## [0.0.2] - 2026-06-01

### Changed
- Releases now publish to RubyGems via GitHub Actions OIDC trusted publishing (`rubygems/release-gem`) — no long-lived API key. Pushing a `v*` tag cuts the release.

### Added
- Local release helpers: `bin/gem-build`, `bin/gem-login`, `bin/gem-push` for manual/bootstrap publishing.

## [0.0.1] - 2026-06-01

First public (pre-1.0) release. Wurk is a 100% API-compatible drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise — same Redis key schema, same job JSON, same Ruby DSL — with fork-based real parallelism, the full Pro + Enterprise feature set in one free gem (no license check), and a precompiled React dashboard.

### Runtime
- Fork-based Swarm: parent forks N children with PID supervision, rolling restart (SIGUSR1), graceful drain (SIGTERM/SIGINT) to `shutdown_timeout`, and global pause/resume (SIGTSTP/SIGCONT).
- Reliable fetcher — atomic `BLMOVE` from the main queue to a per-process private list — with orphan reclamation on boot; Processor runs the middleware chain; Manager owns the thread pool, lifecycle, and heartbeat.
- Scheduled-set and retry pollers; EVALSHA-cached Lua on the hot paths; per-fork Redis pool over redis-client; Redis-outage client buffer.
- `reliable_push` opt-in `:raise` overflow policy with a background drainer.
- Cluster leader election with periodic firing consolidated onto the leader.
- StatsD metrics across hot paths; liveness HTTP endpoint for Kubernetes probes; expired-job counter for `expires_in`.

### Batches
- Sidekiq Pro Batch API: `on(:success/:complete/:death)` callbacks, live progress, nested batches, autoflush + linger, nested death cascade, and per-callback rescue.

### Limiters
- Enterprise rate limiters — concurrent, bucket, window, leaky, and points — each exposing a uniform live `#status` (`used`/`limit`/`reset_at`/`available?`); concurrent additionally reports metric counters. Includes a poison-pill brake.

### Periodic
- Cron loops (sidekiq-cron compatible): schedule parsing with timezone/DST handling, leader-gated firing, pause/resume, enqueue-now, and fire history.

### Encryption
- Transparent job-payload encryption with key rotation and graceful failure modes (a decryption failure degrades rather than crashing the worker).

### Dashboard
- Precompiled React + TypeScript SPA mounted under the engine — consumers never run Node. Tabs: queues, retries, scheduled, dead, busy, processes, batches (+ per-batch detail), limiters, periodic, metrics, and search. SSE live updates, read-only mode, pagination, i18n with host-app override, and a dark default theme.

### Compat
- `Sidekiq::*` aliases for every public `Wurk::*` class (`Sidekiq::Worker`, `Sidekiq::Batch`, `Sidekiq::Limiter`, `Sidekiq.configure_server`, …) — the drop-in contract.
- ActiveJob adapter, `IterableJob`, embedded mode, and a standalone `exe/wurk` runner.
- Sidekiq client/server middleware contract; third-party ecosystem suites (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-status, sidekiq-failures, sidekiq-throttled) pass against Wurk.

[Unreleased]: https://github.com/developerz-ai/wurk/compare/v1.0.0-rc1...HEAD
[1.0.0.rc1]: https://github.com/developerz-ai/wurk/compare/v0.0.5...v1.0.0-rc1
[0.0.5]: https://github.com/developerz-ai/wurk/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/developerz-ai/wurk/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/developerz-ai/wurk/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/developerz-ai/wurk/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/developerz-ai/wurk/releases/tag/v0.0.1
