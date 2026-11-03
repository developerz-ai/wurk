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
- `COMMAND` — optional, what runs the suite when `rake test` is not it. Comments
  say what it leaves out.
- `prepare` — optional, edits the fresh checkout, mostly a hardcoded Redis.
- `adapter.rb` — optional, a test-only shim the suite loads, for an assertion on
  something no production code can observe. Says why at the top.
- `boot_check.rb` — the gem loaded into the real executables, asserting it did its
  job. A suite can stay green without a Launcher ever booting.

`bin/test-ecosystem` clones each pin into `.checkouts/` (gitignored, cached),
checks out the SHA, and runs the gem's own `rake test` under the overlay
Gemfile. The suite's failures are the spec: fix wurk, or document the
divergence as intentional.

Run: `bin/rake test:ecosystem` (wraps `bin/test-ecosystem`).
Redis: each run boots a throwaway `redis-server` on a free port, because these suites
flush their DB around every example. CI passes its service as `ECOSYSTEM_REDIS_URL`,
which must name DB 15 and not the local default port; anything else aborts. After
`prepare`, the checkout is scanned for anything left pointing at DB 0 or port 6379.
`REDIS_SCAN_ALLOW` lists files that only look that way, each with its reason.

Current matrix:
- sidekiq-cron (v2.4.0)
- sidekiq-unique-jobs (v8.1.0), without the one spec file that needs Toxiproxy
- sidekiq-failures (1.1.0), without the test for upstream's ERB home page
- sentry-sidekiq (6.5.0)

Each `boot_check.rb` runs under `sidekiq` and under `wurkswarm` with the preload on,
off, and with fake testing mode switched on as the app loads (`boot_check_support.rb`).

A harness lands here only once it is green. A suite that cannot pass yet is a
red check on every PR in the repo, which buys nothing and hides real
regressions — so the pin, and what still blocks it, is recorded in
`docs/idea/14-ecosystem-compat.md` until the gap is closed.

Target additions (see `docs/idea/14-ecosystem-compat.md`): sidekiq-status,
sidekiq-scheduler, sidekiq-throttled.
