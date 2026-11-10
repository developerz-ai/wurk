# 07 — Ecosystem gems + Sidekiq 7.x Pro/Ent migration fitness

> Part of [`overview.md`](overview.md). Depends on: [`02`](02-boot-and-adoption-dx.md) B4–B6, B10. E2 blocked on [`12`](12-human-decisions.md) H7 (Redis dump).

Test of fitness = `~/workspace/tesote/treasury` (sidekiq 7.3.10 + pro 7.3.60006 + ent 7.3.40004; 171 `Sidekiq::Job`, 136 `lock:` via sidekiq-unique-jobs, cron, failures, sentry-sidekiq, OTel, skylight, rspec-sidekiq). **Treasury is read-only — never edit it.** Finding: treasury uses almost no Pro/Ent API (`super_fetch!`, web, `sidekiqswarm`); nearly every surface resolves in wurk. The breakers are listed here. Next adopter pool (still on Sidekiq): `tesote/proxy-manager`, `tesote/rails-boilerplate`, `tesote/ai-dev`, `developerz-ai/mmarketing.site`, `developerz-ai/venom.is`, `developerz-ai/sitelocaleai.com`, `hiscore/sitelocaleai.com`.

**Licensed-source rule:** `~/workspace/tesote/sidekiq` holds licensed Pro/Ent source. Do not read it for implementation, do not copy from it. E2's key shape was observed there by the sweep; it must be re-established from a Redis dump (H7) before any code depends on it.

## Files to change

| ID | Pri | Where | Problem | Change |
|---|---|---|---|---|
| E1 | P1 | `lib/wurk/job_retry.rb:164` (ms timestamps), `lib/wurk/preflight/checks.rb`, `docs/migrate-from-sidekiq.md` ("Millisecond timestamps") | Wurk writes ms (as Sidekiq 8). 7.x apps reading `item['failed_at']`/`enqueued_at` as seconds break silently — treasury: monitoring `Time.at(failed_at)` (constant false alerts), snapshot dates in year ~58,000, inflated KPI. Hits any 7→8 upgrade too. | (a) B10 source scan (`--app`) — the main fix. (b) Ship a RuboCop cop `Wurk/RawJobTimestamp` in `lib/rubocop/cop/wurk/` (opt-in require; no runtime dep on rubocop). (c) `config.legacy_float_timestamps` for 7.x migrants + symmetric rollback = H8 (changes what wurk writes; allowed only as restoring a Sidekiq format, and only by decision). |
| E2 | P1 | `docs/target/sidekiq-pro.md` §3.2, `lib/wurk/fetcher/private_list_key.rb`, `lib/wurk/preflight/keyspace.rb:75`, `lib/wurk/fetcher/reaper.rb` | Spec says Pro private lists are `queue:<q>\|<host>\|<pid>\|<idx>`; sweep observed 7.3 naming `queue:sq\|<identity>\|<queue>` tracked via `super_processes` + `<identity>:super_queues`. If true: crash orphans from the Pro era are never reclaimed after cutover; preflight reports them only as `unparseable_lists`. | After H7 dump confirms shapes: fix spec §3.2 + guide; preflight names the shape and counts jobs; reclaim path for `sq\|` lists whose identity is absent from `processes` (read-only of Pro bookkeeping keys; writes only `RPUSH queue:<q>` + list removal — existing key semantics). Parity oracle from the dump fixture. Until then: guide says "drain Pro fully and check `wurk preflight` shows 0 unparseable lists before cutover". |
| E3 | P1 | `test/ecosystem/` (harness pattern: `PIN` + overlay `Gemfile` + `prepare`/`EXCLUDE`/`COMMAND`/`adapter.rb` + `boot_check.rb`; see `test/ecosystem/README.md`) | Coverage vs what adopters run: sidekiq-cron tested at 2.4.0 — treasury runs 2.3.1 (9 web-suite failures on `Sec-Fetch-Site`, per `docs/idea/14-ecosystem-compat.md`), yet guide §10 lists 2.3.1 as "in CI". opentelemetry-instrumentation-sidekiq (prepends `Processor#process_one/#fetch`, `Launcher#heartbeat`, `Scheduled::Poller#enqueue/#wait`), rspec-sidekiq, skylight: smoke-only or untested. | Add harnesses: OTel (boot_check asserts `:startup` prepends attach + a job produces a span), rspec-sidekiq (suite minus Ent matchers). Skylight: boot_check only. cron: fix the doc claim; recommend ≥2.4.0 in guide + preflight (B10). |
| E4 | P2 | `docs/idea/14-ecosystem-compat.md`, `test/ecosystem/README.md`, new harness dirs | sidekiq-status: blocker in doc is stale (`lib/wurk/compat.rb:122` aliases `WebHelpers`; `lib/wurk/web/helpers.rb:14` mutable `SAFE_QPARAMS`). sidekiq-scheduler + sidekiq-throttled: no pin, no recorded blocker (README claims they are recorded). Throttled patches fetch; `Sidekiq::BasicFetch` aliases `Wurk::Fetcher::Reliable` (`compat.rb:121`) — unknown fit. | sidekiq-status harness with `web_spec` excluded (same pattern as sidekiq-failures). Pin + run scheduler and throttled once; record measured blockers (or green) in the doc. Throttled: if its requeue path leaves a private-list copy, that is a wurk bug (see `Fetcher::UnitOfWork#requeue`) — fix, don't exclude. |
| E5 | P1 | every `test/ecosystem/*/boot_check.rb` | sidekiq-cron "never fired" shipped because the gem's own suite never boots a Launcher (`aca53f6`). | Each harness's boot_check starts a real `Wurk::Launcher` (embedded, throwaway redis-server), enqueues through the gem's feature, asserts the job **ran**. |
| E6 | P2 | new `test/integration/mixed_fleet_test.rb`, `bench/vs_sidekiq/Gemfile` (stock sidekiq available) | Mixed Sidekiq + Wurk fleet on one Redis never tested (old audit R4); guide says unsupported (`docs/migrate-from-sidekiq.md:101-107`), preflight only warns. | Test what actually happens: stock 8.x process + wurk process, same queues, 5k jobs incl. retries + scheduled: zero lost, zero duplicated beyond documented windows; `ProcessSet`/Busy page coherent. Outcome → either "supported for rolling cutover" with the proof, or a precise list of what breaks. |
| E7 | P2 | `test/unit/cli_test.rb` (or the swarm CLI test file) | Untested Ent-compat invocations used by treasury's Coolify deploy: `SIDEKIQ_PRELOAD=''`, `sidekiqswarm -r <path>/config/environment.rb` with config discovered from cwd (`lib/wurk/cli.rb:492-499,674-703`), `SIDEKIQ_COUNT`, `SIDEKIQ_PRELOAD_APP=1`. | CLI tests replaying those exact invocations. |
| E8 | P3 | `test/unit/` | `Sidekiq::Client.prepend(Mod)` overriding `push_bulk` (treasury's transaction guard) — supported but untested; `Sidekiq::Queues.jobs_by_class` — 0 test refs. | Add both to parity/unit. |
| E9 | P2 | `docs/migrate-from-sidekiq.md` | Guide gaps + contradictions: `:444` "Only sidekiq-cron" in CI (4 are); `:1188` "does not render ERB extensions" (1.11.0 does, `docs/dashboard.md:114-135`); no "from 7.x" checklist; behaviour deltas adopters must brief (deferred ACK re-run window on SIGKILL, recovered jobs go to queue front, poison kills fire death handlers, metrics history starts empty) are scattered. | Fix contradictions. Add "Migrating from Sidekiq 7.x Pro/Ent" section: ordered checklist = bundle edits (drop `connection_pool < 3` pin, remove Pro/Ent source, shim/`exe/sidekiq`) → `wurk preflight --app` → `wurk boot-check` in CI → drain → cutover → `wurk verify` → rollback. One table of runtime deltas. |

## Steps
1. PR-a: E9 doc truth + E3 doc fix + E4 doc fix (no code).
2. PR-b: E5 (real-worker boot checks for the 4 existing harnesses).
3. PR-c: E3 new harnesses; PR-d: E4 harnesses.
4. PR-e: E6 mixed fleet; PR-f: E7 + E8.
5. E1(b) cop with B10; E2 after H7.
6. Ecosystem runs: `bin/rake test:ecosystem` (own throwaway `redis-server`; never DB 0).

## Tests
- Listed per row. E6 uses a jid ledger (shared helper with [`09`](09-proof-harness.md) T1).
- `bin/check full` for ecosystem + Python lanes.

## Done when
- Every plugin gem found in an adopter or adopter-pool lockfile is either in `test/ecosystem` with a job-actually-ran check, or listed with a measured blocker in `docs/idea/14-ecosystem-compat.md`.
- `wurk preflight --app` run against a treasury-shaped fixture flags E1 and (after H7) E2 with remedies.
- Mixed-fleet behaviour is a tested fact, stated in the guide.
- Guide has no claim contradicted by CI or by another doc.
