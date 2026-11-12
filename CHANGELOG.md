# Changelog

All notable changes to Wurk are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [Semantic Versioning](https://semver.org/).

Each release's notes live in their own file under [`docs/changelog/`](docs/changelog/); this page is the index, newest first. Not released yet: [`docs/changelog/unreleased.md`](docs/changelog/unreleased.md) ([diff since the last release][Unreleased]). A pull request with a user-visible change adds its line there.

## [1.15.0] - 2026-11-12

Observability and operator release: `/metrics` gains swarm restart and crash-streak, Redis round-trip, pool, scheduler and per-class duration families; the dashboard filters retries, scheduled and dead jobs and acts on every match, works under a strict CSP and a path prefix; and `/v1` ships an OpenAPI spec with admin retry and queue-clear routes. [Release notes](docs/changelog/1.15.0.md).

## [1.14.0] - 2026-11-11

Performance release: the dashboard takes a fixed number of Redis round trips per read and loads 777 KB → ~104 KB brotli, `require "wurk"` loads 41% fewer files, a concurrent-limited job costs 2 round trips instead of 6, and a memory limit below a fresh child's size no longer fork-loops the swarm. [Release notes](docs/changelog/1.14.0.md).

## [1.13.0] - 2026-11-11

`bundle exec sidekiq` and Sidekiq Web's probe and stats routes work after the gem swap, `wurk boot-check` can no longer write Redis, and job logs report `elapsed` in seconds as Sidekiq does. [Release notes](docs/changelog/1.13.0.md).

## [1.12.0] - 2026-11-11

A poison-pill job is no longer handed to a live worker while it is being killed; `wurk boot-check` and boot warnings catch worker-only crash loops and silent misconfiguration; `unique_for`, `retry_for` and `timeout` given as Durations work. [Release notes](docs/changelog/1.12.0.md).

## [1.11.1] - 2026-11-06

Periodic fixes from a production rollback: a loop whose class is gone no longer becomes a retry storm, and `config.periodic` registers when the server boots instead of while initializers load. [Release notes](docs/changelog/1.11.1.md).

## [1.11.0] - 2026-11-03

Fixes a 1.10.0 boot regression under `wurkswarm`: upgrade if your `config/application.rb` relies on the swarm's preload. [Release notes](docs/changelog/1.11.0.md).

## [1.10.0] - 2026-11-02

**Upgrade if you run on Dragonfly.** 1.9.0 and earlier could lose jobs on a Dragonfly at `maxmemory`, on Redis-compatible paths that are safe on Redis and Valkey. [Release notes](docs/changelog/1.10.0.md).

## [1.9.0] - 2026-10-29

`concurrent-ruby` is no longer a runtime dependency, dashboard metrics history is 30 days instead of 3, and reaper, middleware-order and metrics-window fixes. [Release notes](docs/changelog/1.9.0.md).

## [1.8.1] - 2026-10-16

`rails runner`, `rails console` and other one-off commands no longer fork a swarm under puma >= 6. [Release notes](docs/changelog/1.8.1.md).

## [1.8.0] - 2026-10-05

The squeaky-clean audit release: a production-grade pass for teams moving a high-volume Sidekiq Pro/Ent deployment onto Wurk. [Release notes](docs/changelog/1.8.0.md).

## [1.7.6] - 2026-09-07

One runtime fix that matters to anyone using encrypted jobs — on json 3.0.0, every one of them failed — plus the repo hygiene that had accumulated since 1.7.5. [Release notes](docs/changelog/1.7.6.md).

## [1.7.5] - 2026-08-27

A second shutdown-correctness release, on the far side of the same fork window 1.7.4 closed. [Release notes](docs/changelog/1.7.5.md).

## [1.7.4] - 2026-08-27

A correctness release about shutdown. [Release notes](docs/changelog/1.7.4.md).

## [1.7.3] - 2026-08-18

A correctness release about how Wurk boots inside a Rails host: `bundle exec wurk` ran two workers, so every job was executed twice. [Release notes](docs/changelog/1.7.3.md).

## [1.7.2] - 2026-08-11

A delivery release: nothing in the runtime changed, but the release lane, the demo image, and the demo's own queues each had a defect that let a green CI run mean less than it looked. [Release notes](docs/changelog/1.7.2.md).

## [1.7.1] - 2026-08-10

A correctness release about what Wurk says about itself. [Release notes](docs/changelog/1.7.1.md).

## [1.7.0] - 2026-08-10

A maintenance release with three unrelated threads: the Ruby that runs between `conn.call(...)` and the socket got cheaper, CI stopped running the same suite four times, and the docs stopped writing about Sidekiq at length. [Release notes](docs/changelog/1.7.0.md).

## [1.6.0] - 2026-08-09

A "beyond Sidekiq" release: eight Wurk-only extras, none of them Sidekiq parity. [Release notes](docs/changelog/1.6.0.md).

## [1.5.0] - 2026-08-07

A performance release, and the first one to publish honest numbers against stock Sidekiq rather than a slogan. [Release notes](docs/changelog/1.5.0.md).

## [1.4.0] - 2026-08-02

A five-agent leak, logic and performance audit of the whole gem, landed over eleven pull requests. [Release notes](docs/changelog/1.4.0.md).

## [1.3.1] - 2026-07-26

Two drop-in gaps found in one production deploy, both of which only bite the worker process — so the web app looks healthy while nothing gets done. [Release notes](docs/changelog/1.3.1.md).

## [1.3.0] - 2026-07-26

Error reporting: an opt-in Sentry integration (`Wurk::Sentry`) that reports job failures, which never reach `config.error_handlers`. [Release notes](docs/changelog/1.3.0.md).

## [1.2.1] - 2026-07-24

Dependency and tooling refresh; no behavior changes to job processing. [Release notes](docs/changelog/1.2.1.md).

## [1.2.0] - 2026-07-21

Fixes a cluster of features that looked enabled but quietly did nothing, found by writing the feature documentation against the implementation. [Release notes](docs/changelog/1.2.0.md).

## [1.1.2] - 2026-07-18

Metrics fixes (double-counted `top_jobs` throughput, false 10× spikes, the per-minute key's year), and a one-round-trip profile persist. [Release notes](docs/changelog/1.1.2.md).

## [1.1.1] - 2026-07-18

Fixes a host-app boot crash in stock production deploys, swarm signal handling (TSTP, USR2, timeout, the fork window) and Redis-outage buffer job loss. [Release notes](docs/changelog/1.1.1.md).

## [1.1.0] - 2026-07-01

The dashboard is rewritten from React to SolidJS, and shows the gem version in the nav. [Release notes](docs/changelog/1.1.0.md).

## [1.0.7] - 2026-07-01

Dashboard: the sidebar collapse motion is unified and smoothed. [Release notes](docs/changelog/1.0.7.md).

## [1.0.6] - 2026-07-01

Dashboard skeleton loaders, route-level Suspense, SEO and icons, and a modular SCSS architecture; benchmarks skip when nothing measurable changed. [Release notes](docs/changelog/1.0.6.md).

## [1.0.5] - 2026-06-25

Dashboard fixes: a white screen on a null `error_class`/`error_message`, and nav icons jumping on collapse. [Release notes](docs/changelog/1.0.5.md).

## [1.0.4] - 2026-06-22

Real critical-path benchmark drivers, and a fix for a stale local dashboard manifest in tests. [Release notes](docs/changelog/1.0.4.md).

## [1.0.3] - 2026-06-16

Rails drop-in fixes (engine auto-load, build-safe boot), the obsidian dashboard redesign, and a de-noised bench gate. [Release notes](docs/changelog/1.0.3.md).

## [1.0.2] - 2026-06-13

Per-request dashboard read-only, and fixes for weighted-queue YAML, `require "wurk"` on Ruby 3.4+ and the dashboard's Quiet/Stop. [Release notes](docs/changelog/1.0.2.md).

## [1.0.1] - 2026-06-11

A cron loop targeting an `ActiveJob` class enqueues it through the ActiveJob adapter. [Release notes](docs/changelog/1.0.1.md).

## [1.0.0] - 2026-06-11

First stable release. [Release notes](docs/changelog/1.0.0.md).

## [0.0.5] - 2026-06-01

Project logo and tagline in the README; the published gem is slimmed to runtime files. [Release notes](docs/changelog/0.0.5.md).

## [0.0.4] - 2026-06-01

`docs/compatibility.md` (compatibility and legal basis) and a dependency refresh. [Release notes](docs/changelog/0.0.4.md).

## [0.0.3] - 2026-06-01

Gem contact email set. [Release notes](docs/changelog/0.0.3.md).

## [0.0.2] - 2026-06-01

Releases publish to RubyGems through GitHub Actions OIDC trusted publishing, and local release helpers. [Release notes](docs/changelog/0.0.2.md).

## [0.0.1] - 2026-06-01

First public (pre-1.0) release. [Release notes](docs/changelog/0.0.1.md).

[Unreleased]: https://github.com/developerz-ai/wurk/compare/v1.15.0...HEAD
[1.15.0]: https://github.com/developerz-ai/wurk/compare/v1.14.0...v1.15.0
[1.14.0]: https://github.com/developerz-ai/wurk/compare/v1.13.0...v1.14.0
[1.13.0]: https://github.com/developerz-ai/wurk/compare/v1.12.0...v1.13.0
[1.12.0]: https://github.com/developerz-ai/wurk/compare/v1.11.1...v1.12.0
[1.11.1]: https://github.com/developerz-ai/wurk/compare/v1.11.0...v1.11.1
[1.11.0]: https://github.com/developerz-ai/wurk/compare/v1.10.0...v1.11.0
[1.10.0]: https://github.com/developerz-ai/wurk/compare/v1.9.0...v1.10.0
[1.9.0]: https://github.com/developerz-ai/wurk/compare/v1.8.1...v1.9.0
[1.8.1]: https://github.com/developerz-ai/wurk/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/developerz-ai/wurk/compare/v1.7.6...v1.8.0
[1.7.6]: https://github.com/developerz-ai/wurk/compare/v1.7.5...v1.7.6
[1.7.5]: https://github.com/developerz-ai/wurk/compare/v1.7.4...v1.7.5
[1.7.4]: https://github.com/developerz-ai/wurk/compare/v1.7.3...v1.7.4
[1.7.3]: https://github.com/developerz-ai/wurk/compare/v1.7.2...v1.7.3
[1.7.2]: https://github.com/developerz-ai/wurk/compare/v1.7.1...v1.7.2
[1.7.1]: https://github.com/developerz-ai/wurk/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/developerz-ai/wurk/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/developerz-ai/wurk/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/developerz-ai/wurk/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/developerz-ai/wurk/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/developerz-ai/wurk/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/developerz-ai/wurk/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/developerz-ai/wurk/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/developerz-ai/wurk/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/developerz-ai/wurk/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/developerz-ai/wurk/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/developerz-ai/wurk/compare/v1.0.7...v1.1.0
[1.0.7]: https://github.com/developerz-ai/wurk/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/developerz-ai/wurk/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/developerz-ai/wurk/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/developerz-ai/wurk/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/developerz-ai/wurk/compare/v1.0.1...v1.0.3
[1.0.1]: https://github.com/developerz-ai/wurk/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/developerz-ai/wurk/compare/v0.0.5...v1.0.0
[0.0.5]: https://github.com/developerz-ai/wurk/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/developerz-ai/wurk/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/developerz-ai/wurk/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/developerz-ai/wurk/releases/tag/v0.0.2
