# 06 — Frontend (dashboard SPA) fixes

> Part of [`overview.md`](overview.md). Depends on: 05 (structured 503s, search truncation flag).

## Files to change

- `frontend/src/App.tsx:146`, `frontend/src/hooks/useSSE.ts:30`, `frontend/src/hooks/useMeta.ts:31`, `frontend/src/hooks/useJobSetActions.ts:40-51`, all 14 pages — hardcoded `/wurk` base.
- `lib/wurk/dashboard_controller.rb` — serves `index.html` verbatim; must inject mount base.
- `frontend/src/pages/Search.tsx` — wrong fields (`retry_at`/`failed_at` never sent, lines 223,301), bypasses `/api/search` (lines 74-99), static query keys, no loading state.
- `frontend/src/hooks/useJobSetActions.ts` + every mutation call site (Retries.tsx:115-176, Queues.tsx:68-222, Busy.tsx:229-242, Cron.tsx:56-65, Limiters.tsx:75-79) — no `onError` anywhere.
- `frontend/src/i18n/*.json` — non-en locales 76/149 keys; `Metrics.tsx`, `Cron.tsx`, `Limiters.tsx`, `Batches.tsx`, `BatchDetail.tsx`, `Profiles.tsx`, `Search.tsx`, `Nav.tsx:142`, `Dead.tsx:125`, `Queues.tsx:247,264` — hardcoded English.
- `frontend/src/pages/Metrics.tsx` — per-job drill-down missing; backend `GET /api/metrics/:klass` (`config/routes.rb:58`) unused.
- `frontend/src/components/Nav.tsx:142` — "System Status: Active" static.

## Steps

1. **Mount-path portability.** Backend: `DashboardController` injects the engine mount point into `index.html` at serve time (`<script>window.__WURK_BASE__ = "<%= mount %>"</script>` or a `<base>` tag; mount from `wurk.` route proxy / `request.script_name`). Frontend: one `basePath()` helper; `Router base`, `EventSource` URL, `useMeta`, `useJobSetActions`, and every `fetch('/wurk/api/…')` go through it (mechanical sweep, grep `'/wurk` in `frontend/src`). Vite dev mode falls back to `/wurk`. Kill every literal.
2. **Mutation error surface.** Minimal toast system (one Solid store + `<Toasts/>` in App shell — no dependency). `useJobSetActions.postJSON` already throws on non-2xx (`useJobSetActions.ts:23`); add default `onError` in the hook itself (toast with status-aware message: 403 read-only, 404 already-gone, 503 redis-unavailable from 05, generic 500) so every existing call site is covered without touching each. Ad-hoc `fetch` mutations (Queues/Busy/Cron/Limiters) migrate to the hook or add `onError`.
3. **Search rewrite.** Use `GET /api/search?substr=` (backend ZSCAN across queues+retries+scheduled+dead — currently dead code); query key includes the term + debounce; render backend's `sorted_entry` fields (`at`, `score`, `error_class`, `error_message` — serializers.rb:55-64), fixing the always-"—" `retry_at`/`failed_at` columns; add loading skeleton; show `truncated` banner (from 05 step 4); i18n all strings incl. pluralization.
4. **i18n completeness.** Extract every hardcoded string listed above into `en.json` keys; fill the 73 missing keys in `es/fr/de/pt-BR/ja/zh-CN` + 12 in `ar` (machine-translate, mark for native review); add a vitest that asserts key-set equality across locale files (guards regression).
5. **Missing features.**
   - Leader badge: expose leadership in `process_row` serializer (backend one-liner reading `dear-leader` vs process identity) → badge on Busy page.
   - Per-job metrics drill-down: make "Top Job Types" rows link to a job-class detail view consuming the existing unused `/api/metrics/:klass` (histogram + backlog).
   - Filter box on Retries/Scheduled/Dead pages wired to the backend `substr` pagination param (`lib/wurk/web/pagination.rb:23` — already supported, never sent).
6. **Small fixes.** `Nav.tsx:142` status chip binds to `useSSE.connected()`; confirm dialog on Limiters "Reset" (`Limiters.tsx:169`); reset `?page` to 1 when a filter/bulk-delete empties the current page; gate the Search `suggestions` query behind first input.
7. **Tests** (the gap that let A1/A2 ship): vitest for `useSSE` (connect/cleanup/fallback), `useJobSetActions` (throw → toast, invalidation), `Pagination` math, Search page (term → endpoint called, fields rendered), locale key-parity test, basePath helper.

## Tests

- `bun run test` in `frontend/` — all new suites above.
- Manual/E2E check: `cd test/dummy && bin/rails s` with engine mounted at a non-`/wurk` path (add a second mount in dummy routes) — SPA fully functional; `bin/rake frontend:build` clean.

## Done when

- Engine mounted at `/sidekiq` (or any path) → dashboard fully works.
- Every failed mutation shows a user-visible error; read-only mode failures explain themselves.
- Search hits the server API, shows correct timestamps, covers all sets incl. queues.
- All locales ship the full key set; locale-parity test green.
- Leader badge + per-job metrics page exist; `/api/metrics/:klass` no longer dead.
