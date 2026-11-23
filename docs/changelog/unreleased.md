# Unreleased

### Added

- **Native sidekiq-cron: drop the gem, keep the code and the Redis state.** Without the `sidekiq-cron` gem in the bundle, `Sidekiq::Cron` is Wurk's own implementation: `Sidekiq::Cron::Job` (`load_from_hash!`, `find`, `all`, `enable!`/`disable!`, …), `Sidekiq::Cron.configure`, `require "sidekiq/cron/web"`, over the gem's own `cron_jobs:<namespace>` / `cron_job:<namespace>:<name>` keys. Entries already in Redis keep their enabled/disabled state, which is keyed by name, so an edited schedule stays disabled. Fires are leader-gated and use the gem's `:enqueued` gate, so old pods on the gem and new pods on Wurk push each occurrence once; an interop run in the `ecosystem` job checks this against the real gem. With the gem bundled, Wurk stands down. The dashboard's Cron page lists the entries beside the periodic loops ([periodic jobs](../periodic-jobs.md#sidekiq-cron-natively-sidekiqcron)).
