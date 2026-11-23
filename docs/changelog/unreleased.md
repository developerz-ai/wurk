# Unreleased

### Added

- **Native sidekiq-cron: drop the gem, keep the code and the Redis state.** Without the `sidekiq-cron` gem in the bundle, `Sidekiq::Cron` is Wurk's own implementation: `Sidekiq::Cron::Job` (`load_from_hash!`, `find`, `all`, `enable!`/`disable!`, …), `Sidekiq::Cron.configure`, `require "sidekiq/cron/web"`, over the gem's own `cron_jobs:<namespace>` / `cron_job:<namespace>:<name>` keys. Entries already in Redis keep their enabled/disabled state, which is keyed by name, so an edited schedule stays disabled. Fires are leader-gated and use the gem's `:enqueued` gate, so old pods on the gem and new pods on Wurk push each occurrence once; an interop run in the `ecosystem` job checks this against the real gem. With the gem bundled, Wurk stands down. The dashboard's Cron page lists the entries beside the periodic loops ([periodic jobs](../periodic-jobs.md#sidekiq-cron-natively-sidekiqcron)).
- **Documented and tested: a Gemfile with `gem "wurk"` alone.** Once no add-on declares `add_dependency "sidekiq"`, the `sidekiq` shim gem can go: Bundler resolves no `sidekiq` gem and every `require "sidekiq…"` path an app uses is a file in wurk's `lib/` ([migration guide](../migrate-from-sidekiq.md#dropping-the-shim-a-gemfile-with-wurk-alone)). The Sentry guide maps `config.sidekiq.report_after_job_retries = true` and a hand-written early-kill death handler onto `Wurk::Sentry.install!` ([Sentry](../sentry.md#coming-from-report_after_job_retries--true)).

### Fixed

- `bin/dummy-bundle` (run by `bin/setup`) no longer exits 1 under `pipefail` when Bundler has no `path` configured.
