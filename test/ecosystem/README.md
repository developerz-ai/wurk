# Ecosystem compat

Third-party Sidekiq gem test suites run against Wurk. The strongest possible drop-in proof.

Each subdirectory is a checked-out gem (or a submodule pin) with its Gemfile rewritten to point Sidekiq → Wurk. The `lib/wurk/compat.rb` alias layer makes this transparent.

Run: `bin/rake test:ecosystem` (wraps `bin/test-ecosystem`).

Target gems (see `docs/idea/14-ecosystem-compat.md`):
- sidekiq-cron
- sidekiq-unique-jobs
- sidekiq-scheduler
- sidekiq-status
- sidekiq-failures
- sidekiq-throttled

A `.keep` is included so the directory exists; populate with checkouts when wiring this up.
