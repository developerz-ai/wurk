# Unreleased

### Added

- **`wurk boot-check`** boots the app exactly as `wurkswarm` does (eager load and routes included), then exits without forking or fetching; `--redis` adds a read-only server check. Run it in CI to catch the worker-only crash loops (an engine controller referenced from an initializer, a missing adapter, load order) that a web or test boot never hits. `docs/migrate-from-sidekiq.md` §9.1 has the CI step.
- **Boot warnings for silent misconfiguration:** jobs whose `unique_for:`/`unique_until:` do nothing because `Sidekiq::Enterprise.unique!` was never called; the real `sidekiq` gem bundled next to Wurk (ERROR naming what pulled it in and the pinned shim line; `WURK_STRICT=1` refuses to boot); an Active Record pool smaller than the job threads. Swarms and embedded workers started by the railtie now run these checks too. `docs/running.md` lists every boot message with its fix.
- **One role-and-size line per process** (`wurk`, `wurkswarm parent`, `swarm parent in <server>`, `embedded in <server>`), e.g. `wurkswarm parent; 2 processes × 3 threads (redis pool 10, fetch 3); AR pool 25`.

### Changed

- The "pool too small" startup error names both sizes and the setting that fixes it.

### Fixed

- **Unique jobs declared with an `ActiveSupport::Duration` release their lock.** `sidekiq_options unique_for: 5.minutes` (ActiveJob included) is written into the job JSON as the string `"300"`, as Sidekiq writes it; the server middleware and death handler ignored a string TTL, so the lock was held until it expired. Payloads already in Redis are covered. Found in production by an adopter.
- **`retry_for` given as a Duration keeps its retry budget.** `sidekiq_options retry_for: 48.hours` was written to the job as `null`, so the job fell back to 25 counted retries; a per-call `set(retry_for: 2.hours)` raised "retry_for over 1000000000". Both now store Integer seconds, as Sidekiq does.
- **`timeout:` and `deadline:` given as Durations are written as plain numbers.** A `timeout: 5.seconds` reached the job as the string `"5"`, which the timeout middleware ignored, so the job ran unbounded. Jobs already queued with a string `timeout` are still unbounded until they finish.
- **Docs:** the poison-pill docs describe the reclaim script (the kill comes on the 4th orphaning, goes straight from the private list to the dead set, and fires death handlers; `PoisonPill.recovered!` replaces `track!`); the wiki and migration guide no longer say clustered Puma forks a duplicate swarm, that `sentry-sidekiq` cannot be installed, or that `reliable_scheduler!` must be kept; the install template links to hosted docs the gem does not ship.
- **A poison-pill job is never handed to a live worker while it is being killed.** The reaper pushed a reclaimed job back onto its public queue and only then counted the recovery, so a worker parked on an idle queue could take the job a 4th time while the reaper moved the same job to the dead set and fired its death handlers (batch `:death`, unique-lock release) mid-run. The count and the requeue-or-kill decision now happen in one script, before the job is visible. Orphans returned by a worker's own reconcile go through the same path. The recovery counter is written together with its 72h TTL, so a Redis blip can no longer leave `super_fetch:recovered:<jid>` with no expiry. Keys, job JSON and dead-set scores are unchanged.
