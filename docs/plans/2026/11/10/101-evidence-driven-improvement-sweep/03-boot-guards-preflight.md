# 03 — Boot guards + preflight (make silent misconfig loud)

> Part of [`overview.md`](overview.md). Depends on: none. Source: 5 adopter apps + treasury read. 3 PRs (G1–G4 · G5–G10 · G11–G15). Every guard = a WARN/ERROR at boot or a `wurk preflight --app` row; none changes runtime behaviour.

## Files to change
| ID | Kind | Where | Evidence | Change |
|---|---|---|---|---|
| G1 | BUG-class | `lib/wurk/boot_checks.rb:64-83` (`warn_on_ignored_locks` — pattern to copy) | `unique_for:` without `unique!` is silently a no-op (`docs/unique-jobs.md:424`). Live in tesote.com: `rails/app/jobs/broadcast_deliver_job.rb:11`, no `unique!` anywhere ([`14`](14-adopter-tesote-com.md)). Current check sees only `lock:` on `Wurk::Worker` subclasses. | Add `warn_on_ignored_unique`: any loaded class (Worker **and** ActiveJob via its `sidekiq_options`) with `unique_for`/`unique_until` while unique middleware is not installed → WARN listing classes + the one-line fix. Auto-enable is a human call ([`13`](13-human-decisions.md) U4). |
| G2 | BUG-class | `lib/sidekiq.rb` / `lib/wurk.rb` load; today only `lib/wurk/preflight/checks.rb:183-189` (`real_sidekiq_gem`) | "half-real/half-wurk hybrid" noted in 3 adopter Gemfiles; nothing at normal boot flags it. | On load: `Gem.loaded_specs['sidekiq']` present and not the shim → ERROR naming the gems whose deps include `sidekiq` + the pinned shim line ([`04`](04-drop-in-surface.md) D2). `WURK_STRICT=1` raises. |
| G3 | DX | `lib/wurk/cli.rb` boot banner; `lib/wurk/rails_boot.rb` | Embedded swarm forked in wrong processes in 5/5 apps historically; `WURK_DISABLED=1` in ≥14 places. Sizing banner was wrong once (sales `35f254a4`). | One boot line per process: role (`wurkswarm parent` / `child i/N` / `wurk` / `embedded in <server>` / `client only: <reason from skip_boot?>`), `N processes × M threads`, Redis pool size, AR pool size if AR loaded. |
| G4 | DX | `lib/wurk/cli.rb:437` | `"Pool size too small for #{name}"` — no sizes, no fix. | Include pool size, concurrency, the option to set. Also WARN when AR pool < concurrency (hiscore `ad2bcc3`: every job died on pool timeouts). |
| G5 | DX | `lib/wurk/boot_checks.rb`; `lib/wurk/preflight/verify.rb:81` (already detects) | Queues with jobs and no consumer: sales `dffc41f9`, tesote.com `7505694` (Active Storage queues). `wurk verify` catches it; nobody runs it. | Leader-only periodic check (reuse verify's query) → WARN + gauge `wurk_queue_unconsumed` ([`11`](11-observability-ops.md)) + dashboard banner ([`09`](09-dashboard.md)). Boot check: Rails framework queue names (Active Storage, Action Mailbox, mailers) not in any live process's queues. |
| G6 | DX | periodic registration (`lib/wurk/configuration.rb:500` `apply_periodic!`, `lib/wurk/cron.rb`) | "Register INLINE… `:startup` registers nothing" (gringotts `rails/config/initializers/wurk/2periodic.rb:21-25`). | WARN when `config.periodic` is called after the periodic set was applied. |
| G7 | DX | `lib/wurk/cli.rb` (non-swarm) | hiscore sets `config.topology` under `bundle exec wurk`; ignored (`config/initializers/wurk.rb:40-51`). | WARN: topology set but runner is single-process. |
| G8 | DX | `lib/wurk/redis_options.rb` / pool build | hiredis driver blocks the fiber scheduler (tesote.com `2redis.rb:8-16`). | WARN when driver is hiredis and server is Falcon / a fiber scheduler is set. |
| G9 | defaults | `lib/wurk/redis_pool.rb` (fetch pool), `lib/wurk/fetcher/reliable.rb` (BLMOVE timeout) | 3 apps raise `read_timeout` to 5s because ~2s BLMOVE trips a 1s client timeout; ~136k Sentry events on sales staging. | Verify current fetch-pool `read_timeout` ≥ BLMOVE timeout + margin when the app passes its own `timeout`/`read_timeout`; if an explicit lower value wins today, clamp for the fetch pool only and log once. Test in `test/unit/redis_options_test.rb`. |
| G10 | new cmd | `lib/wurk/cli.rb` subcommands (follow `preflight`/`verify`/`health` dispatch) | Worker boot path ≠ web/test path → prod crash loops in 5/5 apps: `uninitialized constant Wurk::Engine` (hiscore `7c4213e`, sales `daa0b0d3`), `WurkAdapter` missing (tesote.com `0a01afa`, legald `02500e9`), CSP initializer → `Wurk::ApplicationController` (sales `110c4443`), `Dotenv` (gringotts `cc2a24fc`). CI was green each time. | `wurk boot-check [-r path] [-C file]`: boots exactly as `wurkswarm`/`wurk` would (same require order, eager_load, routes drawn, all G-checks, YAML parsed), opens no fetch, forks nothing, needs no Redis unless `--redis`; exit 0 / non-zero + actionable message. Ship a CI recipe in `docs/migrate-from-sidekiq.md` §9. |
| G11 | preflight | `lib/wurk/preflight/checks.rb` `--app` rows | treasury reads `failed_at` as seconds: `app/sidekiq/monitoring/sidekiq_monitoring_job.rb:118`, `app/services/monitoring/sidekiq_snapshot.rb:103,136`; wurk writes ms (`lib/wurk/job_retry.rb:164`). | `--app` source scan with the guide's regex (`\[['"](failed_at\|created_at\|enqueued_at\|retried_at)['"]\]`) over `app/ lib/ config/` → INFO rows with file:line. |
| G12 | preflight | same | treasury `Gemfile:22` pins `connection_pool ~> 2.5`; `wurk.gemspec:56` needs ≥3. | `--app` row from `Gemfile.lock` when resolvable; documented one-liner otherwise. |
| G13 | preflight | same | `Rails.error` subscriber may see per-attempt job errors ([`05`](05-errors-and-test-mode.md) E1). | `--app` INFO when a `Rails.error` subscriber is registered. |
| G14 | preflight | same | Web process would fork a swarm in dev single-mode Puma next to a `Procfile.dev` worker; `flushdb` in `on(:startup)` then runs per child (treasury `config/initializers/sidekiq/1server.rb:7-9`; 3 adopters carry the same dev flush). | `--app` WARN: Procfile has a worker entry and web would embed; WARN on `flushdb`/`flushall` inside lifecycle hooks (source scan). |
| G15 | preflight | same | Plugin versions outside the CI pins (`test/ecosystem/*/PIN`) — treasury runs sidekiq-cron 2.3.1 vs pin 2.4.0; `defined?(Sidekiq::Pro::…)` guards go dead. | `--app` INFO rows: bundled plugin version vs tested pin; list of Pro/Ent-constant guards found. |

## Steps
1. `BootChecks` owns boot WARNs (`lib/CLAUDE.md`); `Preflight` owns `--app` rows. No check moves into `Configuration`.
2. Each guard: one method, one unit test with a fake class/spec. Follow `locked_job_classes` (`boot_checks.rb:77-84`) for safe class walks (`NAME.bind_call`).
3. G10 reuses `CLI#run_swarm` boot minus fork/fetch; do not add a second boot path.
4. Docs: one "Boot messages" table in `docs/running.md` (message → cause → fix).

## Tests
- `test/unit/boot_checks_test.rb` per guard; `test/unit/preflight_*_test.rb` per row.
- `test/integration/boot_check_cli_test.rb`: dummy app passes; dummy with an initializer referencing an engine controller fails non-zero with the constant named.
- `bin/check`.

## Done when
- Each row G1–G15 has a test that fails without the guard.
- Running `wurk boot-check` against `test/dummy` exits 0 in CI.
- `wurk preflight --app` on a treasury checkout (read-only, no Redis writes) lists G11 (2 sites), G12, G15.
