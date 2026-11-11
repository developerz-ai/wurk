# Unreleased

### Added

- **Measurement tooling** for contributors: `bin/profile vs_sidekiq` (per-job CPU and per-stage frame attribution against stock Sidekiq), `bin/rake bench:require_profile` (require cost per entry point), `bin/rake bench:rss_soak` (per-child Rss/Pss over 100k jobs), `bin/rake bench:soak` (chaos soak with a jid ledger; nightly `soak.yml`), and `bin/rake bench:algo` / `bench:algo_counts` (dashboard and feature round-trip budgets, enforced in CI). Results from 2026-11-11 are in `docs/benchmarks.md` with raw data under `docs/benchmarks/2026-11-11/`.

### Fixed

- **Docs:** `docs/reliability.md` lists a job that finished while Redis was down as a duplicate window (its ACK fails, so it runs again once requeued; never a loss), and `docs/batches.md` says a batch callback is enqueued at most once but its job runs at least once, so callbacks must be idempotent. Both were observed by the new chaos soak.
