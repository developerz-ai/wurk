# 04 — Web layer + dashboard

> Part of [`overview.md`](overview.md). Depends on: none. Source: web audit 2026-10-04 (read-only). Historical audit baseline (2026-10-04): `bun run lint` clean, `bun run test` 282/282 green, 8 locales × 259 keys in sync, `vendor/assets/` built by `release.yml` (in sync).

**Current source recount (separate from the historical baseline):** 8 locales registered in `LOCALES` in `frontend/src/i18n/index.ts`: `en`, `es`, `fr`, `de`, `pt-BR`, `ja`, `zh-CN`, and `ar`, imported from their corresponding JSON bundles in `frontend/src/i18n/`. `frontend/src/i18n/en.json` contains **260 English leaf strings**. Counting method: recursively traverse object values, count each string-valued leaf once by its key path (including nested `search.kind` and `flows.state` leaves), and exclude object branches themselves. Manual subtotals: nav 25, dashboard 27, table 34, summaries 13, busy 18, cron 5, job 10, search 13, extension 3, actions 28, readonly 1, toast 7, common 12, limiters 2, queues 2, batches 8, flows 20, metrics 21, timezone 5, theme 3, notfound 3 = 260. This source recount does not revalidate the historical count or locale-parity claim; tests, lint, and build were not rerun.

Ordered by customer impact. W1–W2 were identified as prod blockers in the historical audit; W1 has landed as recorded below, while W2 remains open.

## Findings

| ID | Sev | Where | Defect | Fix direction |
|---|---|---|---|---|
| W1 | P1 sec | `lib/wurk/web/rack_app.rb:27–36` (`Wurk::Web.call`), `lib/wurk/web/config.rb:474–494` | Historical defect: `mount Sidekiq::Web` skipped `config.authorization` + `read_only`; extension routes were served unauthenticated (curl w/ forged `Sec-Fetch-Site`), and the authentication rationale was wrong for Ent. | **Landed (source inspection):** standalone dispatch is wrapped in `Authorization` with `api_handoff: false`, inside host middleware; authorization runs before the read-only gate. Corrected standalone-gate and CSRF documentation: `docs/authentication.md:357–379`. Existing regression coverage: `test/unit/web_rack_app_test.rb:112–174` (see Tests). |
| W2 | P1 avail | `app/controllers/concerns/wurk/stream_concurrency_guard.rb:21`, `api_controller.rb:321` | SSE cap 10 > Puma threads (Rails default 3; `demo/config/puma.rb` 5). 3–5 tabs pin every request thread for 120s → host app hangs. | Cap = `max(1, server_threads/2)` (read `RAILS_MAX_THREADS`/Puma config), configurable `config.web.max_streams`; document. Consider shorter stream lifetime. |
| W3 | P1 | `frontend/src/pages/Busy.tsx:101,227`, `Cron.tsx:51`, `Metrics.tsx:166-190,423,484,533`, `Profiles.tsx:34` | raw `fetch().then(r=>r.json())`, no `r.ok`; 503 body crashes page; `components/ErrorBoundary.tsx` never resets → whole SPA dead until reload. | Use shared `getJSON` everywhere; key/reset ErrorBoundary on route path. Grep `fetch(` in `frontend/src` — zero raw calls left. |
| W4 | P1 UX | `frontend/src/pages/Retries.tsx:94-115` (+ `Dead.tsx`, `Scheduled.tsx`) | New query key → `isPending` → FilterBox unmounted, focus + keystrokes lost. | `placeholderData: keepPreviousData`, or render header/FilterBox outside `<Switch>`. |
| W5 | P1 | `app/controllers/wurk/api/pagination.rb:20,31` + `frontend/src/components/Pagination.tsx:11` | Server clamps `MAX_PAGE=1000`, UI ignores → pages >1001 show page 1001; bulk-select hits wrong rows. | Server returns 400 or `max_page`; UI caps + honours returned `page`. |
| W6 | P1 | `config/routes.rb:59` (`limiters/:name/reset`, `cron/:lid/*`, `flows/:fid`, `batches/:bid`) | No segment constraint → dotted names 404. | `constraints: { name: %r{[^/]+} }` like `queues/:name`. |
| W7 | P2 avail | `lib/wurk/health.rb:151,161` | `gets("\r\n")` unbounded, no deadline, single accept thread on `0.0.0.0`; slowloris → `/live` `/ready` hang → k8s kills healthy pods. | `read_nonblock` with overall deadline + 8 KB cap; per-connection timeout. |
| W8 | P2 compat | `lib/wurk/web/config.rb:365-415` | Missing `Sidekiq::Web.locales`, `.views`, `.middlewares` → NoMethodError at boot for gems using them. | Delegate to config (`views` → no-op array). |
| W9 | P2 compat | `lib/wurk/web/extension.rb:192-261`, `extensions_controller.rb:43` | Extension `Action` lacks `halt`, `json`, `reload_page`, `render(:erb,…)`; content-type forced HTML. | `throw :wurk_ext_halt` with status/ctype/body; pass ctype through `respond_with`. |
| W10 | P2 | `app/controllers/wurk/api_controller.rb:451`, `Retries.tsx:126-131` | Filtered list returns unfiltered `total`; "Retry/Kill/Delete all" shows full count while filtered. | Return `filtered_total` (or lower-bound flag); label/disable "all" actions when filtered. |
| W11 | P2 | `frontend/src/hooks/useSSE.ts:31-40` | EventSource gives up on non-200 (503 cap/redis); no reopen; controller comment claims reconnect/Retry-After. | onerror + `readyState===CLOSED` → reopen w/ backoff; fix comment. |
| W12 | P2 compat | `frontend/src/App.tsx:177-196` | No catch-all; Sidekiq paths (`/morgue`, `/queues/:name`, `/retries/:key`, `/metrics/:klass`) blank. | Alias routes + `*` NotFound. |
| W13 | P2 | `frontend/src/pages/Extension.tsx:73-80,115` | innerHTML: extension `<script>` never runs; Cmd/Ctrl/middle-click hijacked. | Skip intercept on modifiers / `button!==0`; document script limitation or re-inject w/ nonce. |
| W14 | P3 sec | `lib/wurk/web/extension.rb:305` | `redirect_target` passes `//evil.com`. | Reject `//` prefix. |
| W15 | P3 sec | `app/controllers/wurk/profiles_controller.rb:30` | GET triggers Firefox-profiler upload (cross-site `<img>`). | Same-origin check on that action. |
| W16 | P3 | `lib/wurk/web/enterprise.rb:44` | `GET /api/limiters` sweeps (SREM) even in read-only. | Skip sweep when `read_only?`. |
| W17 | P3 | `lib/wurk/web/search.rb:67,153`; 11 hardcoded `aria-label`s; `config.rb:262` single-stack cache; 32 possibly-unused `en.json` keys | Misc. | `truncated?` at limit + dedupe ZSCAN; i18n aria labels; cache both stacks; verify dynamic keys before deleting. |

## Steps
1. **W1 landed (source inspection):** `Wurk::Web.call` wraps standalone dispatch in `Authorization` with `api_handoff: false` (`lib/wurk/web/rack_app.rb:27–36`); authorization and read-only enforcement are in `lib/wurk/web/config.rb:474–494`. The corrected standalone authentication documentation is at `docs/authentication.md:357–379`; existing regression coverage is at `test/unit/web_rack_app_test.rb:112–174`. This status records inspected implementation and coverage, not a claim that tests were rerun.
2. W2 + W11 together (SSE server cap + client reconnect).
3. W7 (health server) — standalone, no engine dependency (standalone mode must not load engine).
4. W3/W4/W5/W10/W12/W13 frontend batch; then `bin/rake frontend:build` locally to sanity-check.
5. W6, W8, W9, W14–W17.

## Tests
- W1 — **existing coverage inspected**, `test/unit/web_rack_app_test.rb:112–174`: `Sidekiq::Web` with denied authorization → 403 on GET and forged-same-origin POST; authorization receives the mount-relative path; read-only → 403 on POST, including API-shaped extension paths, while GET remains available; host middleware runs before authorization. These are existing test assertions, not a test-execution result.
- W2: cap N-1 → N streams open → plain GET still answered (engine test).
- W3: vitest Busy with `/api/processes` 503 → error state, no throw; navigate → recovers.
- W4: vitest type filter, advance timers → input still mounted + focused.
- W5: API `page=5000` → 400/`max_page`; Pagination cap test.
- W6: engine test reset limiter `a.b`.
- W7: socket writes 1 byte + stalls; second `/live` answers < 2s.
- W8: `Sidekiq::Web.locales.equal?(config.locales)`.
- W9: extension routes using `json` and `halt 404`.
- W12: routing test `/morgue` → Dead.
- Commands: `bin/rake test TEST=...`, `cd frontend && bun run test && bun run lint`, `bin/check fast`.

## Done when
- All W1–W13 fixed with tests; W14–W17 fixed or ticketed.
- `grep -rn "fetch(" frontend/src --include=*.tsx` shows only the shared helper.
- `bin/check` green; coverage ≥90/90.
