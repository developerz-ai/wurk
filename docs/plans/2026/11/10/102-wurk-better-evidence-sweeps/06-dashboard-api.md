# 06 — Dashboard + HTTP API

> Part of [`overview.md`](overview.md). Depends on: none. W6 shared with [`05`](05-memory.md) M10.

Source: surfaces sweep (static read; CSP / sub-path / API-only behaviour marked "inference" there — reproduce in `test/dummy` before fixing). Stack: Rails engine (`app/`), SolidJS + bun + Vite (`frontend/`), prebuilt bundle in `vendor/assets/dashboard`. Read `frontend/CLAUDE.md` first: TS strict, oxlint, `to-rem()` lengths.

## Files to change

| ID | Pri | Where | Problem | Change |
|---|---|---|---|---|
| W1 | P1 | `app/controllers/wurk/dashboard_controller.rb:57-60,95-101`, `vendor/assets/dashboard/index.html` (built from `frontend/index.html`), `frontend/src/basePath.ts` | Shell injects inline `<script>` (`__WURK_BASE__`, `__WURK_THEME__`, pre-paint theme) with no nonce; no CSP doc/test. Strict `script-src` blocks it → base falls back to `/wurk` → non-default mounts break silently. An adopter's CSP initializer already crashed a worker referencing `Wurk::ApplicationController`. | Base + theme as `data-*` on `#wurk-root`; pre-paint script → external file in the bundle. Engine test with strict CSP initializer in `test/dummy`; CSP section in `docs/dashboard.md` (incl. how to scope a CSP to the engine without referencing engine constants at boot). |
| W2 | P1 | `lib/wurk/engine.rb:22-81` (`AssetMount`), `frontend/vite.config.*`, `index.html` asset URLs | Absolute `/wurk-assets/…` URLs (breaks under `RAILS_RELATIVE_URL_ROOT`/proxied sub-path — inference); served uncompressed outside `Rack::Deflater` (~0.7 MB cold). | Build emits `.br`/`.gz`; `AssetMount` negotiates `Accept-Encoding`; asset prefix from `request.script_name`/relative root. Dummy-app test under a relative root. |
| W3 | P2 | `frontend/src/tailwind.css:6` (all of Font Awesome for 47 icons; brands font for one icon, `Nav.tsx:266`), `frontend/src/i18n/index.ts:1-8` (8 locales eager), og-image in gem | Bundle 1.8 MB. | Inline SVG icon subset; `import()` locales; drop og-image/Twitter meta from the authenticated shell. Record before/after bytes in PR. |
| W4 | P1 | `app/controllers/wurk/api/pagination.rb:24,74-95,103-133`, `lib/wurk/batch_set.rb:26-38`, `lib/wurk/batch/status.rb:21-25`, `lib/wurk/flow_set.rb:39-45`, `lib/wurk/sorted_entry.rb:25-29` | Offset paging walks every row before the offset; batches/flows do 1 `HGETALL` per skipped row (≤25,000 per request at `MAX_PAGE`); sorted sets JSON-parse skipped entries. `?substr=` on batches/flows can never match (`match?` checks klass/jid only). | Unfiltered window: direct `ZRANGE key start stop REV` (add `JobSet#page(offset, count)`; batches/flows page the index zset then hydrate only the window, pipelined). Fix or remove `substr` for batches/flows. |
| W5 | P2 | `app/controllers/concerns/wurk/sse_streaming.rb:44-46`, `app/controllers/wurk/api/serializers.rb:17-29`, `lib/wurk/stats.rb:35-88` | Each SSE tick: `SMEMBERS queues` ×2 + `LLEN` per queue ×2 + … ≈ 3Q+P+12 commands / 2s / open tab. | Derive `enqueued` from the queue summaries inside `stats_payload`; one pipelined pass. |
| W6 | P2 | `lib/wurk/web/enterprise.rb:46-67`, `frontend/src/pages/Limiters.tsx:75` | GET Limiters runs a sweep (`SREM`) every 5s per viewer. | GET pure; sweep moves to leader housekeeping (M10). |
| W7 | P1 | `app/controllers/concerns/wurk/same_origin_guard.rb:32-37`, `frontend/src/toast.tsx:56-59`, `frontend/src/http.ts:49-53`, `docs/authentication.md` | Mutations over plain HTTP: browsers send no `Sec-Fetch-Site` → 403 → UI says "read-only mode". `getJSON` drops error bodies → generic page errors. | Distinct JSON error (`cross_site` vs `read_only`) + distinct toast; `http.ts` surfaces the body; doc paragraph on plain-HTTP internal hosts. Do not weaken the guard. |
| W8 | P1 | `app/controllers/wurk/…/profiles` route, `config/routes.rb`, read-only authorization hook (`lib/wurk/web/config.rb`) | `GET /profiles/:key` uploads to the public Firefox profiler; an adopter blocks it by hand for read-only sessions. | Treat as privileged under `read_only` (a GET with an external side effect). Test in `test/engine`. |
| W9 | P2 | `config/routes.rb:64-65`, new compat controller | Stock monitoring endpoints missing (ledger `docs/idea/parity-divergences.md:1093,1160,1196,1222`): `GET /stats`, `/stats/queues`, `/dashboard/stats`, `HEAD /`, `?direction=asc`, `?days=N`. Uptime scripts written for Sidekiq break. | Implement to `docs/target/sidekiq-free.md` shapes exactly; parity oracle per route; remove the ledger entries. |
| W10 | P2 | `app/controllers/wurk/api_controller.rb:409` (bulk cap 1,000), `pagination.rb` | No "apply to all matching": filter matches klass/jid only, stops at 20k rows; cannot "retry all `Timeout::Error`". | `POST /api/<set>/matching/:cmd` — server-side `ZSCAN` with the same budget, filters: class, error class, error message substring; streams in pages (uses A8 batching). UI: "apply to all N matches". |
| W11 | P3 | `config/routes.rb`, `frontend/src/pages/Batches.tsx:58` | Pro "Dead batches" tab + batch tag filter have no route. | Add per `docs/target/sidekiq-pro.md` web section. |
| W12 | P2 | `frontend/src/pages/*` | No tests for BatchDetail, Batches, Cron, Dead, Flows, Limiters, Profiles, Scheduled pages (28 test files total); no browser e2e, no axe. | Vitest per missing page; Playwright + axe smoke against `test/dummy` in the `frontend` CI job (advisory first). Use the `run-dashboard` skill to drive it locally. |
| W13 | P2 | new `docs/openapi.yaml`, `lib/wurk/api/router.rb` (`Router#routes`), `lib/wurk/api/jobs.rb:35-46`, `lib/wurk/api/queues.rb:33-43`, `clients/python/tests/` | No OpenAPI spec; Python tests mock `urlopen`; `docs/api-http.md:190-196` example shows `"wurk_version": "8.4.0"`. | Commit spec; unit test walks `Router#routes` ↔ spec paths/scopes; integration boots `exe/wurk api` and runs the Python client against it; fix the example. |
| W14 | P3 | `lib/wurk/api/` | Operator API lacks set mutations (retry/kill entry, queue clear, retry-all), `GET /batches`, metrics. Automation must drive the CSRF-guarded dashboard JSON. | Admin-scoped routes mirroring dashboard actions; in OpenAPI. |
| W15 | P3 | new `docs/job-format.md` | "Same job JSON" claimed; no user-facing field/key contract for non-Ruby producers. | Doc from `docs/target/sidekiq-free.md` §2.1 (required fields, `queues` SADD, `queue:<name>` LPUSH, `schedule` score); parity test round-trips a hand-built payload. |
| W16 | P3 | (large) | `run Sidekiq::Web` outside Rails serves extensions only (ledger `:1590`) — Sinatra/Roda/Hanami apps get no dashboard. | Rack-mode SPA host. Scope + go/no-go = H6; not scheduled here. |

## Steps
1. PR-a (security/UX truth): W7, W8.
2. PR-b: W1 + W2 (shell + asset serving; rebuild bundle with `bin/rake frontend:build`).
3. PR-c: W4 + W5 + W6 (Ruby-side cost).
4. PR-d: W9 parity routes.
5. PR-e: W10 + W11; PR-f: W3 + W12; PR-g: W13–W15.
6. Dashboard commands, in `frontend/`: `bun run test`, `bun run typecheck`, `bun run lint`.

## Tests
- W1: `test/engine` with strict CSP → shell renders, base path correct on a non-default mount.
- W4: `CommandSpy` — page 400 of batches issues O(per_page) commands.
- W5: `CommandSpy` — one stats tick ≤ Q+P+c commands.
- W9: `test/parity/` oracles vs stock responses.
- W13: spec↔router test; Python client integration (`bin/check full` lane).

## Done when
- Dashboard renders under a strict CSP and under a relative URL root (both tested).
- Cold load transfer size recorded before/after; deep pages O(page) Redis commands.
- A read-only session can trigger no external side effect.
- OpenAPI spec exists and is enforced against the router.
