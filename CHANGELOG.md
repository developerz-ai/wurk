# Changelog

All notable changes to Wurk are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.2] - 2026-07-18

### Fixed
- **Metrics — `top_jobs` double-counted throughput and the per-job series had false 10× spikes** — the writer kept a `j|<date>|H:m0` 10-minute rollup whose key format collides with the real minute-0 bucket, so every job at a minute ending 1–9 was also folded into that decade's `x0` key, turning it into a decade total. `Metrics::Query` then summed the `x0` bucket alongside the individual minutes, roughly doubling every count in the Metrics "top jobs" table and putting a ~10× spike at every `:00/:10/:20…` point on the per-job chart. The rollup is removed (stock Sidekiq never persisted it — its daily/hourly rollups are commented out — and reads the last N per-minute keys), which fixes the count with no read-side change and drops ~⅓ of the per-job metric-write commands on the hot path.
- **Metrics — per-minute key now uses a 4-digit year (`j|YYYYMMDD|…`)** — the bucket key used a 2-digit year (`j|YYMMDD|…`) while stock Sidekiq (and Wurk's own deploy-marks key) use `YYYYMMDD`, so a Sidekiq→Wurk drop-in swap silently orphaned the existing metrics history. Keys now match Sidekiq, so migrated data resolves unchanged.

### Changed
- **Profiler — profile persist is one round-trip** — `Profiler.store` pipelines its `HSET` + `EXPIRE` + `ZADD` (was three sequential calls). Same keys/TTL; off the hot path (opt-in profiling).

## [1.1.1] - 2026-07-18

### Fixed
- **Engine — host app boot crash in stock production deploys** — the dashboard asset middleware was inserted with `insert_before(ActionDispatch::Static, …)`, but Rails omits `ActionDispatch::Static` whenever `public_file_server` is disabled (any production deploy behind nginx with `RAILS_SERVE_STATIC_FILES` unset), so `initialize!` raised and the host app would not boot with the gem installed. The middleware now inserts at index 0, which is equivalent (it only intercepts `/wurk-assets/*`) and always valid.
- **Dashboard "Stop" left a standalone process as a zombie** — a TERM queued via the dashboard (`Wurk::Process#stop!`) was dispatched by calling `Launcher#stop` directly on the heartbeat thread: `stop_heartbeat` self-joined (`ThreadError`), skipping heartbeat cleanup and exit hooks, and nothing woke the main thread — the process stopped fetching but never exited, and in a swarm the slot was silently lost. Standalone processes now re-deliver the signal to themselves (`Process.kill`) so the real trap path runs; embedded launchers (which own no traps, and where a self-TERM would kill the host) run quiet/stop on a separate thread with a self-join guard.
- **Swarm — TSTP quiet now sticks across respawn/recycle** — quieting the swarm only relayed TSTP to the children alive at that moment; a crashed or memory-recycled child's replacement booted fetching, violating the one-way global quiet (spec §21.3). The swarm now records the quiet state and forks replacements pre-quieted (a constructor flag, not a racy post-fork signal).
- **Swarm — USR2 to the parent no longer kills the fleet** — the parent had no USR2 trap, so a logrotate config signalling the master pid hit the default disposition and terminated the whole swarm. USR2 is now trapped and relayed to children (log reopen).
- **Swarm — `-t/timeout` finally reaches the supervisor** — the CLI and railtie built the Swarm without `shutdown_timeout`, so the parent SIGKILLed children at the 25s default even when `-t 60` promised them a longer drain, cutting off `bulk_requeue`. The configured timeout is now plumbed through, plus a 5s grace so the children's post-drain tail (requeue + heartbeat cleanup) always fits.
- **Swarm — fork-window signal theft** — a signal delivered to a freshly-forked child before it reset its inherited traps was written into the parent's self-pipe (TERMing one child pid could drain the entire swarm). Children now close the inherited pipe FDs first thing, so the stale trap write no-ops; also frees 2 leaked FDs per child.
- **Client — Redis-outage buffer no longer drops jobs on non-connection errors** — `drain!` popped a buffered job before replaying it, but only connection errors restored it; a recovering Redis answering `OOM`/`LOADING`/`READONLY` permanently discarded one buffered job per drain tick, silently. Every error path now restores the popped payload first.
- **Client — outage-buffer drainer replayed into the wrong Redis** — the drainer captured the origin pool from a nonexistent ivar, always got `nil`, and silently replayed explicit-pool jobs into the default Redis; the one-shot factory guard then blocked any later correct capture. It reads the right ivar now and never installs a nil-pool factory.
- **Scheduler — post-outage promotion no longer stalls Redis** — the reliable scheduler's Lua promote swept every due member in one atomic call; a 100k-job backlog blocked all Redis clients for the whole sweep. Promotion is now batched (500/call, looped until dry).
- **Limiter — `config.redis=` reset the wrong memo** — reassigning the limiter Redis after first use kept returning the stale pool forever.
- **Batch — death of a stale job no longer resurrects expired batch keys TTL-less** — a job dying after its batch's 30-day expiry recreated `b-<bid>*` keys with no TTL (permanent leakage per occurrence). The death handler now re-stamps `EXPIRE … NX` on the batch keys.
- **Cron — Vixie step semantics for single-value bases** — `5/15` in a field parsed as just `[5]`; it now expands to `5-max/15` (5,20,35,50) matching Vixie cron / fugit / Sidekiq Ent.
- **API parity — `set(wait:/wait_until:)` with a past/zero target enqueues immediately** (Sidekiq drops `at` when not in the future) instead of parking in the schedule ZSET; `retry_for` deadline math no longer misreads millisecond timestamps (`Time.at` third-arg unit).
- **Web API hardening** — `?page=` is clamped (array params no longer 500), substr-filtered pages count offsets in match space (no more duplicated/skipped rows across pages) under a 20k-row scan budget, `keys[]` bulk actions cap at 1000, "add all scheduled to queue" snapshots the set so it terminates under concurrent scheduling and never early-enqueues jobs scheduled after the click, `GET /profiles/:key` (which uploads to the public Firefox profiler store) is blocked in read-only mode, and extension render errors no longer leak exception messages to viewers.
- **Web API — fewer Redis round-trips** — the profiles list pipelines `HMGET` of metadata only (previously one `HGETALL` per profile, dragging each multi-MB gzipped blob through Redis per render); queue-job delete uses the single-Lua fast path instead of a paged queue walk.
- **Tests — cron DST assertions were host-timezone-dependent** — `TZInfo#utc_to_local` reinterprets a non-UTC `Time`'s wall clock as UTC; the fold assertions now convert to UTC first (they passed on UTC CI but failed on any non-UTC machine).

### Changed
- **Dev — one-command local dashboard loop** — `bin/dev` boots Redis (reused or a throwaway Docker container), the Vite dev server (SolidJS HMR), and the `test/dummy` Rails host wired with `WURK_VITE_DEV=1`, so editing `frontend/src` hot-reloads the dashboard at `/wurk` with no rebuild. `bin/setup` now uses **bun** (not the removed `npm ci`) and installs the dummy app's gems into a project-local path so a permission-locked global gem home no longer fails setup with `Bundler::PermissionError`. Contributor docs updated. (#286)
- **CI — prune old demo images from GHCR** — `deploy-demo` now deletes stale `wurk-demo` container versions after each push (keeps the newest 5 for rollback; non-blocking), so the registry doesn't grow unbounded across demo deploys. `.playwright-mcp/` and the dummy's local bundle path are gitignored. (#286)
- **Deps** — dashboard: `@solidjs/router` 0.16, TypeScript 7 (dev-only), vitest group minors; CI: `actions/checkout` v7, `docker/build-push-action` v7, `actions/upload-pages-artifact` v5, minor action bumps. (#299–#304)

## [1.1.0] - 2026-07-01

### Added
- **Dashboard — gem version in the nav** — the running Wurk version now renders as a small monospace chip next to the "Wurk" wordmark in the sidebar (above the System Status line), sourced from a new `version` field on `/wurk/api/meta`. The field is optional, so a dashboard talking to an older server just hides the chip. (#285)

### Changed
- **Dashboard — full rewrite from React to SolidJS** — the entire dashboard SPA was migrated off React 19 onto **SolidJS 1.9** with `@solidjs/router`, `@tanstack/solid-query`, and a hand-rolled dependency-free SVG chart module replacing Recharts. Solid's fine-grained reactivity compiles the JSX to direct DOM updates (no virtual DOM / re-render), so the shipped bundle is dramatically smaller and faster: the initial entry chunk drops from ~305 kB to **~35 kB (12.6 kB gzip)**, every page stays a lazy-loaded code-split chunk behind the route-level `<Suspense>` skeleton, and the charts split into their own ~13 kB chunk loaded only on the Dashboard/Metrics tabs. This is an **internal rewrite only** — the dashboard is visually and behaviorally identical (same routes, SSE live updates, i18n, RTL, dark-only Obsidian design system, read-only mode, extension tabs, skeleton loaders), the Redis/JSON/SSE wire contracts are untouched, and the precompiled bundle still ships in the gem (contributors need bun; consumers run neither Node nor bun). Recharts is replaced by a small internal `components/charts/` module (responsive SVG area/line/bar charts with gradient fills, monospace axes, hover crosshair + tooltip) so no charting dependency ships at all. The Vitest suite is rebuilt on `@solidjs/testing-library` with expanded unit (utils, i18n, hooks, charts) and integration (routing, read-only banner, bulk-action flows, page rendering) coverage, running fast in parallel across a worker-thread pool. (#285)

## [1.0.7] - 2026-07-01

### Changed
- **Dashboard — sidebar collapse motion unified + smoothed** — the collapsible left rail was the last piece of UI still using hardcoded transition durations (the component is inline-styled). Its transitions — and the `App.tsx` content-margin that must move with the rail — now run off the shared `--dur-*` / `--ease-*` scale, so the rail width and the content shift animate in exact lockstep instead of at two independently-hardcoded rates. The collapse/expand glide is retuned to `var(--dur-page)` (350 ms) with the emphasized decelerate curve (`var(--ease-emphasized)`) for a noticeably smoother feel; nav-link/icon hovers use `var(--dur-base)`. Reduced-motion carve-outs preserved. (#282, #283)

## [1.0.6] - 2026-07-01

### Added
- **Dashboard — skeleton loaders + route-level Suspense** — every page is now a lazy-loaded code-split chunk behind a single `<Suspense>` boundary (initial JS chunk ~779 kB → ~305 kB; Recharts split into its own chunk loaded only on chart pages), streaming each tab in on navigation. Spinner loading states are replaced with content-shaped **skeleton** placeholders (`components/Skeleton.tsx` — `SkeletonTable`/`SkeletonCards`/`Skeleton`) that mirror the incoming layout, so data arrival no longer shifts the page. Skeletons shimmer via CSS and freeze to a static tint under `prefers-reduced-motion`. A route-level error boundary turns a lazy-chunk load failure (e.g. a stale client after a deploy) into a localized reload prompt instead of a blank screen. (#279)
- **Dashboard — SEO, social + icons** — the SPA shell gains a meta description, `theme-color`/`color-scheme`, Open Graph + Twitter card tags with a 1200×630 share image, and a full favicon/apple-touch-icon set. The source logo is re-optimized (~41% smaller WebP). (#279)

### Changed
- **Dashboard — SCSS architecture (SOLID/SRP) + bun** — the single 1,200-line `styles.css` is refactored into a modular SCSS system under `frontend/src/styles/` (`abstracts/` maps·functions·mixins·CSS-var tokens·keyframes → `base/` → `components/` → `layout/` → `pages/`, composed by `main.scss`), one responsibility per partial. Tailwind + daisyUI directives move to a sibling `tailwind.css`; the SCSS `:root` tokens (unlayered) still override daisyUI's theme, so the rendered look is unchanged. All lengths are `to-rem()` (accessibility: sizes scale with the user's browser font-size), and every transition runs off a shared duration/easing scale (`--dur-*` / `--ease-*`) for consistent, smooth motion. The frontend toolchain moves from npm to **bun** (`bun install` + `bun run build`) across the Rakefile, CI workflows, and the demo Dockerfile; consumers still run neither Node nor bun. (#279)
- **CI — skip benchmarks when nothing measurable changed** — the `bench` workflow (including the expensive 8vcpu best-of-3 `compare` job) now runs only when Ruby/bench inputs change (`lib`, `exe`, `bench`, `bin/bench-compare`, `Rakefile`, `Gemfile[.lock]`, `*.gemspec`, the workflow itself), so frontend-, docs-, and test-only PRs no longer spin up bench runners. The measurement methodology (best-of-3, same-machine base-vs-head, noise-aware gate) is unchanged. (#280)

## [1.0.5] - 2026-06-25

### Fixed
- **Dashboard — null `error_class`/`error_message` white-screen** — `/wurk/dead`, `/wurk/search`, and `/wurk/retries` crashed to a blank page when a dead/retry entry had no error fields. Only `JobRetry#stamp_error` stamps those fields, so any job that reached the dead set via `DeadSet#kill`, "kill all", encryption route-to-dead, or a direct Sidekiq migration carried `null` — and the SPA fed it straight into `truncate(s: string)`, throwing `null.length`. `truncate` is now null-safe and the dead-set serializer coerces both fields to `""` (the `DeadSet#kill` stored payload stays raw/Sidekiq-wire-compatible). The `error_class`/`error_message` TS types are corrected to `string | null` so `tsc` enforces the contract. (#272)
- **Dashboard — nav icons jump right on collapse** — clicking the rail collapse toggle applied `justify-content: center` to the nav items instantly while the nav width animated 248→64px, so the icons/logo re-centred against the still-wide nav and leapt right before gliding back. The collapsed controls are now pinned to a fixed rail-width box anchored at the nav's start edge, so each glyph's centre stays on the constant rail mid-line throughout the animation. (#272)

## [1.0.4] - 2026-06-22

### Changed
- **Benchmarks — real critical-path drivers** — the `fetch+execute`, `swarm boot`, and `memory` benches were `TODO` stubs, so the CLAUDE.md "Faster" pillar's >5%-regression gate could not verify three of its critical paths. All three now drive the real code against real Redis (isolated logical DBs, mirroring the test layer) and emit `benchmark/ips`-compatible lines the PR `compare` gate picks up: `fetch+execute` runs the reliable fetcher + processor middleware chain + ack in a closed loop (#259); `swarm boot` boots a real fork-based swarm and measures fork→reconnect→first-heartbeat latency as boots/sec (#265); `memory` counts hot-path allocations via `GC.stat` and reports jobs-per-1k-allocations so an allocation regression trips the same gate (#266). (#259, #265, #266)

### Fixed
- **Tests — stale local dashboard manifest** — the dashboard bundle under `vendor/assets/dashboard` is a gitignored build artifact, so after a version bump a developer's locally-built `wurk-manifest.json` lagged `Wurk::VERSION` and `StaticAssetsTest` failed a clean `rake test` until `rake frontend:build` was rerun. The manifest/asset-presence assertions now enforce strictly in CI (which rebuilds the SPA first) but skip a missing-or-stale bundle locally, so a clean checkout runs green without Node. (#257)

## [1.0.3] - 2026-06-16

### Fixed
- **Rails drop-in — engine auto-load** — a host following the README/migration guide (`gem "wurk"`, no `require:`) only loaded the standalone entry point, so the engine/railtie never loaded and `ActiveJob::QueueAdapters::WurkAdapter` was undefined; `config.active_job.queue_adapter = :wurk` then raised `NameError` at boot. `lib/wurk.rb` now mirrors stock Sidekiq and auto-loads `wurk/rails` when Rails is present (idempotent with an explicit `require "wurk/rails"`; the no-Rails/standalone path stays fully Rails-free). (#246, #249)
- **Rails drop-in — build-safe boot** — `Railtie.skip_boot?` didn't cover the build context, so the default Rails Dockerfile's `SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile` fired `after_initialize`, forked the swarm, and tried to connect to Redis during `docker build` (no Redis there → hang/fail). A new `Railtie.building?` skips boot when `SECRET_KEY_BASE_DUMMY` is set or any rake task is running; `rails server` / `puma` boot via `Rails::Command`, not Rake, so the real server path is unaffected. (#247, #249)

### Changed
- **Dashboard — obsidian redesign** — the dashboard adopts the monochromatic "obsidian" design system (collapsible left rail, range filters, loading states) and the landing page gains per-tier `BorderGlow` on the tier cards. (#248)
- **CI — bench gate de-noised (best-of-N)** — the PR `compare` job intermittently flagged the low-throughput `push_bulk(1000)` bench (~250 i/s) as a regression on pure runner noise: at that iteration count a single noisy base-vs-head pair could clear even the noise-aware ± band (e.g. #249 saw a spurious -18.2% over a ±13.3% band; the re-run passed). The job now runs the bench suite three times per side and `bin/bench-compare` keeps the fastest run per benchmark, so the cross-process tail (GC, runner CPU contention) is damped. Best-of-N is applied symmetrically to base and head, so a real regression — slower on every run — still fails the gate. (#250)

## [1.0.2] - 2026-06-13

### Added
- **Dashboard — per-request read-only** — `/api/meta` now reports a per-request `read_only` flag derived from the registered authorization hook, so a viewer-role user (a hook that permits `GET` but denies mutations) sees the SPA hide destructive actions instead of showing buttons that then 403. The probe asks the hook about `POST` on a canonical mutating route (`/api/retries`) so a path-sensitive hook resolves it the same way the Authorization middleware resolves the real mutation. With no hook registered the flag still reflects global read-only mode. (#244)

### Fixed
- **Config — weighted-queue YAML** — loading a real `sidekiq.yml` with weighted queues in the nested-array form (`queues:` → `- [critical, 2]`, which YAML parses to `["critical", 2]`) crashed at boot with `Integer(): " 2]"` because the queue parser only handled the `"name,weight"` string form. The capsule parser now accepts both the string and nested-array forms; a malformed array entry with extra elements is rejected with an `ArgumentError` rather than silently truncated. (#242)
- **Packaging / standalone** — `require "wurk"` raised `LoadError: cannot load such file -- base64` on Ruby 3.4+ in any non-Rails app. The code requires `base64` and `logger`, which Ruby moved out of the default gems (base64 in 3.4, logger in 3.5); a Rails app pulled them in transitively, masking the gap, but a standalone consumer had neither. Both are now declared runtime dependencies, so the "run without Rails" path works on current Ruby. (#237)
- **Dashboard — Quiet/Stop** — clicking **Quiet** (or **Stop**) on a worker in the Busy page made it silently vanish from the dashboard instead of reporting as quieted. `Launcher#@done` was overloaded: the heartbeat loop ran `until @done`, and `#quiet` set that same flag, so quieting terminated the heartbeat thread — the process never published `quiet=true` and then expired out of the live `processes` set. The quiet ("stop fetching, stay alive") and shutdown ("stop heartbeating") concerns are now split, so a quieted worker keeps beating and stays visible as quiet; `#stop` still drains and removes it. Affected every `wurkswarm` worker. (#236)

## [1.0.1] - 2026-06-11

### Fixed
- **Cron / Periodic** — a cron loop targeting an `ActiveJob` class now enqueues it through the ActiveJob adapter (`perform_later` → `Sidekiq::ActiveJob::Wrapper`) instead of pushing it as a bare Sidekiq worker. Previously the poller did a raw `client.push('class' => "MyActiveJob")`, so the processor would call `MyActiveJob.new.perform` and skip all of ActiveJob (callbacks, argument deserialization, retries). Matches sidekiq-cron behavior. An explicit cron `queue:` still overrides; otherwise the job's own `queue_as` is respected.

## [1.0.0] - 2026-06-11

First stable release. Wurk is a 100% drop-in replacement for Sidekiq, Sidekiq
Pro, and Sidekiq Enterprise — same Redis schema, same job JSON, same Ruby DSL —
with fork-based parallelism and a precompiled React dashboard, all free in one
gem. This release completes OSS + Pro + Ent feature parity (roadmap #147) and
adds a `require "sidekiq"` compatibility entrypoint so existing apps and
third-party gems swap in with a one-line `gem "sidekiq"` → `gem "wurk"` change.

### Added
- **`require "sidekiq"` drop-in** — a `sidekiq` compatibility shim gem + entrypoint so existing apps and ecosystem gems load Wurk transparently; validated by a real third-party ecosystem suite (sidekiq-cron green on Wurk). (#204)
- **`Sidekiq::Testing`** — `inline!` / `fake!` / `disable!` (global or block-scoped), the in-memory `Sidekiq::Queues` store, and the `Worker`/`Job` test helpers (`.jobs`, `.clear`, `.drain`, `.perform_one`, `.process_job`, `.drain_all`, `.clear_all`) + `Sidekiq::EmptyQueueError`.
- **IterableJob enumerator helpers** — `array_enumerator`, `csv_enumerator` / `csv_batches_enumerator`, and the `active_record_*_enumerator` family, with Sidekiq cursor parity. (#200)
- **Periodic / cron** — public `Sidekiq::CronParser` with `#next` for cron-expression introspection (#201); per-loop execution history in the dashboard (#117).
- **Enterprise historical metrics** — `Sidekiq::History` snapshotter + `config.retain_history` DSL (#123), the `history:metrics` capped Redis stream for migration parity (#125), and per-queue size/latency historical gauges in the dashboard (#124, #126).
- **Swarm lifecycle** — honor `SIDEKIQ_MAXMEM_MB` for memory-based child recycling (#119) and fire an `on(:fork)` lifecycle event in each child after fork (#121).
- **Dashboard** — render third-party Web-extension views/assets natively in the SPA (#187); design follow-ups: human-readable latency, host-grouped Busy page, count-up stats (#217).

### Changed
- **Keyless releases** — the release workflow publishes to RubyGems via **trusted publishing (OIDC)**, no long-lived `GEM_HOST_API_KEY`. On a `v*` tag it precompiles the dashboard, gates (`release:check` verifies the git tag matches `Wurk::VERSION` and the asset manifest is non-empty), builds the gem and asserts the dashboard bundle ships *inside* the `.gem` (`release:package`), `gem push`es via the OIDC token, and cuts a GitHub Release with the matching CHANGELOG section as notes and the `.gem` attached.
- CI standardized on Blacksmith runners with consistent concurrency + job timeouts. (#230)

### Fixed
- **Boot** — enter server mode before the host app loads so `Sidekiq.configure_server` blocks fire in real workers. (#191)
- **Batches (Pro)** — gate a parent batch's `:complete`/`:success` on still-running child batches (#209); fire `:success` correctly after a dead job is manually retried to success, including the ancestor-batch case (#212, #226); persist `Batch#on` callbacks registered after the first `#jobs` flush instead of dropping them (#213).
- **Unique jobs (Ent)** — re-push the job's own jid at schedule/retry promotion instead of losing it to its own lock, and release the lock when a job dies automatically. (#205, #211)
- **Cron (Ent)** — resolve IANA timezone strings via TZInfo instead of mutating process-global `ENV['TZ']`, so concurrent jobs never observe the wrong zone. (#210)
- **Scheduling (Pro)** — compute `expires_in` for a scheduled job from its schedule time, not enqueue time, so a delay longer than `expires_in` no longer makes the job born-expired. (#208)
- **Data API (OSS)** — `Sidekiq::Stats#queues` / `#queue_summaries` sort by size descending to match Sidekiq (#214); fix `SortedEntry#retry` / `#add_to_queue` retry_count handling and fire death handlers on API kill (#206, #207).
- **Dashboard** — redact encrypted job arguments as `"<encrypted>"`. (#118)
- **Test reliability** — give the interrupt-repush integration test's completion clock the same load budget as its boot clock, and 2× that under the coverage CI leg, so it no longer flakes under full-suite CPU saturation. (#216)

## [0.0.5] - 2026-06-01

### Added
- Project logo and a tagline in the README (rendered on GitHub and the RubyGems page).

### Changed
- Slimmed the published gem to runtime files only — Ruby, the precompiled dashboard (js/css/html + asset manifest), engine config, README, and LICENSE. CHANGELOG/CONTRIBUTING/SECURITY are no longer packaged (still on GitHub via the gem's metadata links).

## [0.0.4] - 2026-06-01

### Added
- `docs/clean-room.md` — compatibility & legal basis: Wurk reimplements the Sidekiq API (clean-room, original implementation), the *Google v. Oracle* rationale, and trademark/nominative-use notes. Linked from the README.

### Changed
- Dependency refresh. GitHub Actions bumped to current majors (`checkout@v6`, `setup-node@v6`, `upload-artifact@v7`) on Node 24, clearing the Node 20 deprecation. Dashboard frontend upgraded to React 19, React Router 7, Recharts 3, Vite 8, and TypeScript 6. Ruby dev/test gems refreshed to latest.

## [0.0.3] - 2026-06-01

### Changed
- Gem contact email set to `admin@developerz.ai`.

## [0.0.2] - 2026-06-01

### Changed
- Releases now publish to RubyGems via GitHub Actions OIDC trusted publishing (`rubygems/release-gem`) — no long-lived API key. Pushing a `v*` tag cuts the release.

### Added
- Local release helpers: `bin/gem-build`, `bin/gem-login`, `bin/gem-push` for manual/bootstrap publishing.

## [0.0.1] - 2026-06-01

First public (pre-1.0) release. Wurk is a 100% API-compatible drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise — same Redis key schema, same job JSON, same Ruby DSL — with fork-based real parallelism, the full Pro + Enterprise feature set in one free gem (no license check), and a precompiled React dashboard.

### Runtime
- Fork-based Swarm: parent forks N children with PID supervision, rolling restart (SIGUSR1), graceful drain (SIGTERM/SIGINT) to `shutdown_timeout`, and global pause/resume (SIGTSTP/SIGCONT).
- Reliable fetcher — atomic `BLMOVE` from the main queue to a per-process private list — with orphan reclamation on boot; Processor runs the middleware chain; Manager owns the thread pool, lifecycle, and heartbeat.
- Scheduled-set and retry pollers; EVALSHA-cached Lua on the hot paths; per-fork Redis pool over redis-client; Redis-outage client buffer.
- `reliable_push` opt-in `:raise` overflow policy with a background drainer.
- Cluster leader election with periodic firing consolidated onto the leader.
- StatsD metrics across hot paths; liveness HTTP endpoint for Kubernetes probes; expired-job counter for `expires_in`.

### Batches
- Sidekiq Pro Batch API: `on(:success/:complete/:death)` callbacks, live progress, nested batches, autoflush + linger, nested death cascade, and per-callback rescue.

### Limiters
- Enterprise rate limiters — concurrent, bucket, window, leaky, and points — each exposing a uniform live `#status` (`used`/`limit`/`reset_at`/`available?`); concurrent additionally reports metric counters. Includes a poison-pill brake.

### Periodic
- Cron loops (sidekiq-cron compatible): schedule parsing with timezone/DST handling, leader-gated firing, pause/resume, enqueue-now, and fire history.

### Encryption
- Transparent job-payload encryption with key rotation and graceful failure modes (a decryption failure degrades rather than crashing the worker).

### Dashboard
- Precompiled React + TypeScript SPA mounted under the engine — consumers never run Node. Tabs: queues, retries, scheduled, dead, busy, processes, batches (+ per-batch detail), limiters, periodic, metrics, and search. SSE live updates, read-only mode, pagination, i18n with host-app override, and a dark default theme.

### Compat
- `Sidekiq::*` aliases for every public `Wurk::*` class (`Sidekiq::Worker`, `Sidekiq::Batch`, `Sidekiq::Limiter`, `Sidekiq.configure_server`, …) — the drop-in contract.
- ActiveJob adapter, `IterableJob`, embedded mode, and a standalone `exe/wurk` runner.
- Sidekiq client/server middleware contract; third-party ecosystem suites (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-status, sidekiq-failures, sidekiq-throttled) pass against Wurk.

[Unreleased]: https://github.com/developerz-ai/wurk/compare/v1.0.0-rc1...HEAD
[1.0.0.rc1]: https://github.com/developerz-ai/wurk/compare/v0.0.5...v1.0.0-rc1
[0.0.5]: https://github.com/developerz-ai/wurk/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/developerz-ai/wurk/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/developerz-ai/wurk/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/developerz-ai/wurk/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/developerz-ai/wurk/releases/tag/v0.0.1
