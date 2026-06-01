# Changelog

All notable changes to Wurk are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `Sidekiq::Testing` drop-in: `inline!` / `fake!` / `disable!` (global or block-scoped), the in-memory `Sidekiq::Queues` store, and the `Worker`/`Job` test helpers (`.jobs`, `.clear`, `.drain`, `.perform_one`, `.process_job`, `.drain_all`, `.clear_all`) + `Sidekiq::EmptyQueueError`.

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

[Unreleased]: https://github.com/developerz-ai/wurk/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/developerz-ai/wurk/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/developerz-ai/wurk/releases/tag/v0.0.1
