# Ecosystem compat

Third-party Sidekiq gem test suites run against Wurk. The strongest possible drop-in proof.

Each `<gem>/` subdirectory is a thin harness — no vendored gem source:

- `PIN` — upstream repo + tag + SHA the suite runs from
- `Gemfile` — overlay mirroring the gem's own Gemfile, with `sidekiq` resolved
  to wurk's shim gem (`ecosystem/sidekiq-shim`) and `wurk` to the repo root.
  The bundle installs **no real sidekiq**; `require "sidekiq"` loads wurk's
  alias layer via `lib/sidekiq.rb`.
- `EXCLUDE` — optional, minitest `--exclude` patterns (one per line, comments
  allowed) for suite entries that diverge for a documented, non-wurk reason.

`bin/test-ecosystem` clones each pin into `.checkouts/` (gitignored, cached),
checks out the SHA, and runs the gem's own `rake test` under the overlay
Gemfile. The suite's failures are the spec: fix wurk, or document the
divergence as intentional.

Run: `bin/rake test:ecosystem` (wraps `bin/test-ecosystem`).
Redis: real instance, DB 15 by default — override with `ECOSYSTEM_REDIS_URL`.
The suite flushes its DB; don't point it at data you care about.

Current matrix:
- sidekiq-cron (v2.4.0)

A harness lands here only once it is green. A suite that cannot pass yet is a
red required check on every PR in the repo, which buys nothing and hides real
regressions — so the pin, and what still blocks it, is recorded in
`docs/idea/14-ecosystem-compat.md` until the gap is closed.

Target additions (see `docs/idea/14-ecosystem-compat.md`): sidekiq-status,
sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-failures, sidekiq-throttled.
