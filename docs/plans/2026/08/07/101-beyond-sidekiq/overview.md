# Beyond Sidekiq

## Goal

Add the features the rest of the job-queue world ships and Sidekiq does not — an HTTP producer API, OpenTelemetry, job status/results, per-job timeouts, debounce/throttle, global queue concurrency, flows — plus three dashboard gaps (locale override, light/dark theme, user-timezone dates), and fix the known [#394](https://github.com/developerz-ai/wurk/issues/394) metrics defect. Cross-ecosystem evidence for every item is in [`00-census.md`](00-census.md).

## The additive invariant

**Nothing here changes what already works.** Every feature is off by default and inert when unused: an app that adopts none of them runs the same code paths, writes the same bytes, and posts the same benchmark numbers as today. Concretely, each slice must show:

- no existing Redis key, JSON field, or score format touched;
- no new Redis command on the default enqueue/fetch/execute path (verify with `bench/command_count.rb`);
- `rake bench` within noise of main **with the feature disabled**;
- existing tests, parity suite, and ecosystem suite untouched — not adjusted to accommodate the feature.

Two slices carry an asterisk and say so in their own file: **10** (global concurrency) is the only one that touches the fetch hot path and is allowed to close as *deferred* on the bench numbers; **03** (light theme) changes existing visuals and is blocked on a maintainer call. Slice **01** is a bug fix — it changes behavior on purpose.

## Context

- Ruby gem + mountable Rails engine, Sidekiq drop-in. **Wire-compat is sacred** (`CLAUDE.md`): no existing Redis key, JSON field, or score format changes. Where a slice adds a job-hash key (05, 06, 08), it says so and cites the precedent — third-party Sidekiq gems already add top-level keys freely, and upstream ignores unknown ones.
- **Free pillar**: no tier, no flag gating, no license check. **Measured pillar**: anything on enqueue/fetch/execute must clear `rake bench` at ≤5%, or move off the hot path. `docs/benchmarks.md` — no "faster" claims.
- Layer ownership table in `CLAUDE.md` is binding. User-facing → engine (`app/`, `lib/wurk/engine.rb`); non-user-facing → plain Ruby under `lib/`. **Standalone mode must run without the engine.**
- Server middleware chain, outermost → innermost (`lib/wurk.rb:258-306`): `InterruptHandler` (prepended, `middleware/interrupt_handler.rb:46`) → `Batch` → `Expiry` → `Limiter` → `Statsd` → `Metrics::History` → perform. Ordering comments at `lib/wurk.rb:258`, `:273`, `:285` are the contract — read before inserting anything.
- Existing JSON API (`config/routes.rb`) is **dashboard-shaped**: SPA payloads, same-origin CSRF (`concerns/wurk/same_origin_guard.rb`), session/`Wurk::Web.use` auth, unversioned, read+mutate only. **No create path.** Slice 07 adds a separate plane, not an extension of this one.
- Dashboard: SolidJS + Vite, shell served by `app/controllers/wurk/dashboard_controller.rb#index` from `vendor/assets/dashboard/index.html`, mount-agnostic via `window.__WURK_BASE__` (`dashboard_controller.rb:41-51`). Build: `bin/rake frontend:build`. Tests: `bun run test` in `frontend/` (vitest).
- Reference patterns to follow, don't reinvent:
  - Additive server middleware: `lib/wurk/middleware/expiry.rb`, registration comment `lib/wurk.rb:258`.
  - Skip-class exception treated as neither success nor failure: `lib/wurk/batch/server_middleware.rb:56`.
  - Lua + EVALSHA cache: `lib/wurk/lua.rb`, `lib/wurk/lua/`.
  - Redis key declaration: `lib/wurk/keys.rb:15-53`.
  - Enqueue path to mirror byte-for-byte: `Wurk::Client#push` (`lib/wurk/client.rb:71`), `#push_bulk` (`:84`).
  - Limiter shape for a new gate: `lib/wurk/limiter/base.rb`, `lib/wurk/limiter/server_middleware.rb`.

## Plan files (execute in order)

0. [`00-census.md`](00-census.md) — reference only, no code. Cross-ecosystem feature census + why each item made the cut.
1. [`01-metrics-interrupted-job.md`](01-metrics-interrupted-job.md) — fix #394: interrupted `IterableJob` booked as a failure. Needs a parity determination first. Independent of everything else.
2. [`02-frontend-locale.md`](02-frontend-locale.md) — locale auto-detect hardening + user override + `Accept-Language` server hint.
3. [`03-frontend-theme.md`](03-frontend-theme.md) — light/dark/system theme system over the existing token layer.
4. [`04-frontend-dates.md`](04-frontend-dates.md) — user-timezone + locale-aware relative and absolute dates.
5. [`05-opentelemetry.md`](05-opentelemetry.md) — W3C trace context on enqueue, linked consumer span on execute. Opt-in middleware pair.
6. [`06-job-status-results.md`](06-job-status-results.md) — `Wurk::Status`: per-jid state, progress, return value, timings. Unlocks 07's `GET /jobs/:jid`, 09, 11.
7. [`07-http-producer-api.md`](07-http-producer-api.md) — versioned token-auth control plane: enqueue over HTTP, job status, **swarm/process/health inspection**, three mount modes, one client library.
8. [`08-timeout-deadline.md`](08-timeout-deadline.md) — per-job `timeout:` / `deadline:`.
9. [`09-debounce-throttle.md`](09-debounce-throttle.md) — two collapse policies on `Wurk::Unique`.
10. [`10-global-concurrency.md`](10-global-concurrency.md) — cluster-wide per-queue cap. Hot path — bench gate in hand.
11. [`11-flows.md`](11-flows.md) — `Wurk::Flow`: parent blocks on a child tree. Built on batches.
12. [`12-docs-site.md`](12-docs-site.md) — docs, README, wiki, site, `llms.txt`, CHANGELOG for everything above.

Slices 02–04 (frontend) touch files disjoint from 05–11 (backend) — safe to run in parallel per `CLAUDE.md` (same checkout, no worktrees, disjoint files). 06 blocks 07 and 11. 12 last.

## Done when

- Every shipped slice's own "Done when" is met.
- `bin/rake test`, `test:parity`, `test:ecosystem` green; SimpleCov ≥90% line **and** branch on `lib/`.
- `rake bench` gate green (no >5% regression on enqueue / fetch+execute / bulk enqueue / swarm boot / memory) **with every new feature disabled** — the default path must be unchanged — and separately measured with each enabled.
- `bun run test` + `tsc -b` green in `frontend/`; `bin/rake frontend:build` produces a working bundle.
- No existing Redis key or job JSON field changed. Any *added* job-hash key documented in `docs/idea/parity-divergences.md`.
- Drop-in proof for slice 07: a job enqueued over HTTP is byte-identical to one from `Wurk::Client#push` and is consumed by a **stock Sidekiq** worker in an integration test.
- Docs updated (slice 12) — no "faster than Sidekiq" claim added anywhere.

## Risks / open questions

- **#394 parity call blocks slice 01.** Upstream `Metrics::ExecutionTracker` is the oracle and `docs/target/sidekiq-free.md` doesn't pin the interrupted case. Decide: (a) does an interrupted run book `p`/`f` at all, (b) does it book `<klass>|ms`. `Metrics::Statsd` (`lib/wurk/metrics/statsd.rb:145`) has the same shape and is Pro §9 — settle both in one pass.
- **Job-hash key additions** (05 traceparent, 06 status opt-in, 08 timeout/deadline) are the one place this plan touches the JSON. Precedent exists (sidekiq-cron, sidekiq-unique-jobs all add keys) but it needs an explicit sign-off before 05 lands, in the shape of `docs/plans/2026/08/06/101-faster-than-sidekiq/00-semantics-signoff.md`.
- **Slice 10 is on the fetch hot path.** The last plan fought to 3 commands/job. A per-queue concurrency gate risks giving that back. If it can't be folded into the existing fetch pipeline, defer it rather than regress.
- **Slice 07 attack surface.** An enqueue endpoint on a mounted engine is remote code execution by job class if auth is weak. Off unless a token is configured; never share the dashboard's session/CSRF model.
- **Theme (03) is a visual-identity change.** `CLAUDE.md` and `docs/idea/08-dashboard.md` both say "dark-only"; `frontend/index.html:9` even ships a `darkreader-lock`. Confirm the maintainer wants light mode before building the palette — the token layer supports it, the design system was authored against dark.
- Slice 11 (flows) is the largest API addition. If it slips, everything before it still ships independently.
