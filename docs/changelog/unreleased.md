# Unreleased

### Added

- **`bundle exec sidekiq` keeps working after the gem swap.** Wurk ships a `sidekiq` executable (and `sidekiqswarm`); the `sidekiq` shim gem no longer ships one, so only one gem in a bundle provides it. The shim depends on exactly its own Wurk version, and the documented recipe pins `tag: "vX.Y.Z"` — add the tag to existing shim lines.
- **Sidekiq Web's probe and stats routes:** `HEAD /` (Redis probe), `GET /stats`, `GET /stats/queues` and `GET /dashboard/stats` are served on every mount with upstream's payload shapes, behind the dashboard's authorization.
- **Process titles like Sidekiq's:** workers title themselves `sidekiq <Sidekiq::VERSION> <tag> [x of y busy]` (plus ` stopping` when quiet), so `ps`-based probes that grep `^sidekiq` keep working; `Sidekiq::Launcher::PROCTITLES` is extensible. A swarm parent titles itself `<binary> <tag> [x of y processes]`.
- **`wurk boot-check --runner wurk`** checks the single-process boot path; the default stays `wurkswarm`.
- **More boot warnings:** a topology set but ignored by single-process `wurk`, Rails framework queues (mail, Active Storage, Action Mailbox) nothing listens to, and the hiredis driver under a fiber scheduler.
- **More `wurk preflight --app` rows:** millisecond time fields read as seconds, a `connection_pool` pin below 3, `Rails.error` subscribers (they see every attempt, as with Sidekiq), a Procfile web process that would also run workers, flushes in boot code, plugin versions off their tested pins, and `defined?(Sidekiq::Pro…)` guards.
- **`Wurk::Sentry.excluded_exceptions`**: the retry signals (`Handled`, `Skip`, `Shutdown`) for `Sentry.init`'s `excluded_exceptions` in a process that does not call `install!`.
- **`docs/idempotency.md`**: when a job runs twice, and how to guard each case.
- `rails g wurk:install` prints the pinned shim line when a bundled gem depends on `sidekiq`, plus Procfile notes; the gem has a short post-install message.

### Changed

- **Job log `elapsed` is in seconds** (`elapsed=0.007`), as Sidekiq logs it. It was milliseconds; log parsers that compensated must change.
- **A swarm parent returns a dead child's in-flight jobs the moment it reaps it**, by exact key (measured 0.15–0.17s after a SIGKILL), and boot-time sweeps share the `super_fetch:reaper` lock, so a deploy or rolling restart of N processes is one keyspace pass.
- **A skipped `configure_client` block in a server logs at DEBUG**, as Sidekiq skips it silently; a WARN fires only when no `configure_server` block ran at all.
- The swarm size line reads `Wurk swarm size: N children (<source>)` instead of `Wurk swarm: forking N children (<source>)`.
- On a shutdown that passes its deadline, each interrupted job is logged at WARN with its class, jid and queue (at most 20 lines) instead of one DEBUG dump.

- **Measurement tooling** for contributors: `bin/profile vs_sidekiq` (per-job CPU and per-stage frame attribution against stock Sidekiq), `bin/rake bench:require_profile` (require cost per entry point), `bin/rake bench:rss_soak` (per-child Rss/Pss over 100k jobs), `bin/rake bench:soak` (chaos soak with a jid ledger; nightly `soak.yml`), and `bin/rake bench:algo` / `bench:algo_counts` (dashboard and feature round-trip budgets, enforced in CI). Results from 2026-11-11 are in `docs/benchmarks.md` with raw data under `docs/benchmarks/2026-11-11/`.

### Fixed

- **`wurk boot-check` can no longer write Redis.** Without `--redis`, Wurk's pools open no connection; with it, they send reads only. Boot code that touches Redis (a `flushdb` in a dev-only `configure_server` block, an enqueue) fails the check, naming its file and line, instead of running against whatever Redis it reached. `wurk preflight --app` boots behind the same read-only guard. Found by an adopter.
- **A poison kill whose script reply was lost still fires death handlers**, `:death` batch callbacks and `on_poison`: the reclaim script is sent once and its outcome read back (#908).
- **Jobs queued by Wurk < 1.12 with a string `timeout`** (`"5"`) are cut at their declared time instead of running unbounded.
- **Docs:** `docs/reliability.md` lists a job that finished while Redis was down as a duplicate window (its ACK fails, so it runs again once requeued; never a loss), and `docs/batches.md` says a batch callback is enqueued at most once but its job runs at least once, so callbacks must be idempotent. Both were observed by the new chaos soak.
