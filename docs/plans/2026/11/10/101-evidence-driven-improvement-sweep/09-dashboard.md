# 09 — Dashboard (engine + SolidJS)

> Part of [`overview.md`](overview.md). Depends on: [`07`](07-algorithms.md) for paging (A-rows live there). 3 PRs (W1–W3 · W4–W7 · W8–W10). Stack: SolidJS + bun + Vite, TS strict, oxlint, `to-rem()` lengths (`frontend/CLAUDE.md`); prebuilt bundle in `vendor/assets/dashboard/`. See a change working: `run-dashboard` skill / `bin/dev`.

## Files to change
| ID | Where | Finding | Change |
|---|---|---|---|
| W1 | `app/controllers/wurk/dashboard_controller.rb` (`mount_base_script`, `inject_theme_default`); `vendor/assets/dashboard/index.html` inline pre-paint script | Inline `<script>`s carry no CSP nonce; no CSP doc, no test. Inferred: `script_src :self` + nonce blocks `window.__WURK_BASE__` → `frontend/src/basePath.ts` falls back to `/wurk` → any other mount breaks. Sales already had a CSP-initializer incident (`110c4443`). | Reproduce first in `test/engine/` with a strict policy. Then stamp `request.content_security_policy_nonce` on injected scripts, or move data to `<script type="application/json">` read by the module. |
| W2 | `vendor/assets/dashboard/index.html` (`/wurk-assets/…` absolute); `lib/wurk/engine.rb` AssetMount `PREFIX` | Inferred: apps under `RAILS_RELATIVE_URL_ROOT` / proxy prefix load the shell, not the assets. | Reproduce with `SCRIPT_NAME=/app/wurk` engine test. Prefix asset URLs where the shell is rewritten; Vite `base` relative. |
| W3 | `app/controllers/concerns/wurk/same_origin_guard.rb:33-37`; `frontend/src/toast.tsx:56-63` | Mutations over plain HTTP always 403 (no `Sec-Fetch-Site`; admitted in `docs/idea/14-ecosystem-compat.md:67`); UI says "read-only mode". | 403 body `{error:'cross_origin'}`; toast branches on it; document HTTPS/localhost requirement in `docs/authentication.md`. Fallback to `Origin`/`Host` = human call U9. |
| W4 | `app/controllers/wurk/api/pagination.rb:125-131` (`match?` = klass + jid), `FILTER_SCAN_LIMIT = 20_000`; `lib/wurk/web/search.rb`; `api_controller.rb:409` (bulk ≤1000 keys) | Can't filter dead/retries by error message or act on all matches. | List filter searches payload (`error_class`, `error_message`, args) with Search's ZSCAN budget; `POST <set>/all/:cmd?substr=` behind a confirm, server-side cursor loop with a cap + progress. |
| W5 | profiles route (legald blocks `GET /profiles/:key` for read-only sessions: `backend/config/initializers/wurk.rb:104-118` — it uploads to the public Firefox profiler) | A GET with an outbound side effect under `read_only`. | Treat as privileged: denied in read-only; the upload becomes an explicit POST. Engine test. |
| W6 | new banners: `frontend/src/` layout + `/api` summary payload (`app/controllers/wurk/api/serializers.rb`) | Operators don't see: unconsumed queues ([`03`](03-boot-guards-preflight.md) G5), processes running embedded in a web server, real-Sidekiq hybrid (G2), mixed fleet (preflight has it). | One "Health notices" strip fed by the same checks `wurk verify` runs (`lib/wurk/preflight/verify.rb`), computed at most once per 30s process-wide. Embedded flag: reuse an existing heartbeat info field if one distinguishes it (check `lib/wurk/heartbeat.rb` info hash; adding a field changes the `info` JSON other Sidekiq tools read — additive Wurk-only keys already exist there? verify before adding). |
| W7 | `lib/wurk/web/` Rack app; `docs/idea/parity-divergences.md:1590-1634` | No dashboard outside Rails: `run Sidekiq::Web` in Sinatra/Roda/`config.ru` = extension routes only. Drop-in gap, effort L. | Design note first (serve shell + assets + JSON API from `Wurk::Web::RackApp`, reuse the plain-Rack router in `lib/wurk/api/`); do not start without owner sign-off — size it in the note. `/stats` routes are in [`04`](04-drop-in-surface.md) D5. |
| W8 | `frontend/src/i18n/index.ts:1-8` (9 locales eager, 104 KB); `frontend/src/tailwind.css:6` (full Font Awesome; 47 icon names used; brands font 115 KB for one `fa-github`, `Nav.tsx:266`); AssetMount `Rack::Files` ahead of any deflater, no `.gz`/`.br` | ~680 KB first load, uncompressed unless a proxy compresses. | Lazy locale chunks; inline SVG sprite for the 47 icons; drop og/twitter meta + 262 KB `og-image.png` from the admin shell; emit `.gz`/`.br` siblings at build, serve on `Accept-Encoding`. Record bundle bytes before/after in the PR. |
| W9 | `app/controllers/wurk/api_controller.rb` batches; `frontend/src/pages/Batches.tsx:58`; `lib/wurk/batch_set.rb` (`scan_tags` exists) | Pro web gaps: batch tag filter, dead-batches tab, `?direction=asc`, `?days=N` (`parity-divergences.md:1196,1222`). Multi-shard `Sidekiq::Pro::Web.with` (`docs/target/sidekiq-pro.md:446+`) = L, defer. | Tag filter + dead batches + the two params; remove their divergence entries. |
| W10 | `frontend/` tests (28 files; none for BatchDetail, Batches, Cron, Dead, Flows, Limiters, Profiles, Scheduled) | Mutating pages untested. | Vitest page tests for Dead + Scheduled + Batches; `docs/dashboard-guide.md` (pages, mounting, CSP, sub-path, plain HTTP, `api_only` apps need cookie/session middleware — verify in `test/dummy` first). |

## Steps
1. W1/W2: failing engine test first; both are inferred from code, not observed.
2. Frontend: `bun run test`, `bun run typecheck`, `bun run lint` in `frontend/`; rebuild with `bin/rake frontend:build` and commit the bundle per `frontend/CLAUDE.md`.
3. Controllers stay thin: checks live in `lib/wurk/preflight/`, serializers in `app/controllers/wurk/api/`.

## Tests
- `bin/rake test TEST=test/engine/<file>_test.rb` per row; `cd frontend && bun run test`.
- `bin/check`.

## Done when
- Strict-CSP and sub-path engine tests green.
- Dead-set filter by error message works on a 100k-entry set within the ZSCAN budget (engine test counts commands).
- Bundle first-load bytes down, numbers in `docs/dashboard-guide.md`.
