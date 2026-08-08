# 04 — User-relative dates & timezones

> Part of [`overview.md`](overview.md). Depends on: 02 (locale resolution) for the formatting locale. Disjoint from backend slices.

## What exists

`frontend/src/utils.ts`:

| Fn | Today | Problem |
|---|---|---|
| `relativeTime(epochSeconds)` | hand-rolled `s`/`m`/`h`/`d` + hardcoded English `" ago"` / `" from now"` | untranslated in all 8 locales; wrong grammar in ja/ar/de; no weeks/months/years — a 400-day-old dead job reads `400d ago` |
| `isoTime(epochSeconds)` | `new Date(ms).toISOString()` for hover titles | always **UTC**, never the user's zone. Guarded against `NaN` (`utils.ts:26-32`) — keep that guard. |
| `formatDuration(seconds)` | `ms`/`s`/`m`/`h`/`d` composites | English unit letters, not localized |
| `formatKb(kb)` | `KB`/`MB`/`GB` | same |

Consumers (don't miss any): `pages/Retries.tsx`, `Scheduled.tsx`, `Dead.tsx`, `Busy.tsx`, `Queues.tsx`, `Cron.tsx`, `Batches.tsx`, `BatchDetail.tsx`, `Search.tsx`, `Limiters.tsx`, `Profiles.tsx`, `Metrics.tsx`, `components/JobDetailModal.tsx`, `components/charts/*`.

All timestamps arrive as **epoch float seconds** from the API (Sidekiq score format) — that stays untouched. This slice is display-only.

## Files to change

- `frontend/src/utils.ts` — rewrite the four formatters over `Intl`.
- new `frontend/src/tz.ts` — resolved timezone + user override.
- `frontend/src/i18n/*.json` — no new strings needed for relative time (`Intl.RelativeTimeFormat` handles it), but **do** add the timezone-picker labels and the "shown in <tz>" affordance.
- new `frontend/src/components/TimezonePicker.tsx` (or fold into the settings surface built in 02/03).
- `frontend/src/components/charts/util.tsx` — axis tick labels are dates; must use the same zone.
- `frontend/src/utils.test.ts` — extend.

## Steps

1. **Locale-aware relative time.** Replace the hand-rolled branch chain with `Intl.RelativeTimeFormat(locale, { numeric: 'auto' })` — gives "yesterday"/"vor 3 Stunden"/"3時間前" for free. Pick the unit by magnitude and extend the ladder past days: second → minute → hour → day → week → month → year. Keep the `Number.isFinite` guard (`utils.ts:3-4`) — sorted-set entries do arrive without a usable timestamp and the `'—'` fallback is deliberate.
2. **Timezone resolution**, highest precedence first:
   1. `localStorage["wurk.tz"]` — explicit user pick.
   2. `Intl.DateTimeFormat().resolvedOptions().timeZone` — the browser's zone (this is "relative to the user" for ~everyone).
   3. `'UTC'`.
   Offer `UTC` as an explicit option — ops people comparing against server logs want it, and it's why the current hardcoded UTC isn't simply a bug.
3. **Absolute times** via `Intl.DateTimeFormat(locale, { timeZone, dateStyle, timeStyle })`. Keep an ISO/UTC rendering available in the hover title alongside the local one — losing UTC entirely would be a regression for log correlation. Keep the `RangeError` guard (`utils.ts:26-30`): `new Date(NaN).toISOString()` throws and unmounts the whole table.
4. **Live-updating relatives.** A `5m ago` cell currently only re-renders when its query refetches. Add one shared interval signal (a single timer for the whole page, not one per cell) that ticks the relative labels. Cheap; `VirtualList.tsx` is already in play for long tables, so don't attach timers per row.
5. `formatDuration` / `formatKb` — use `Intl.NumberFormat` with `style: 'unit'` where the unit exists (`second`, `hour`, `kilobyte`, `megabyte`). Composite forms ("21m 49s") have no `Intl` equivalent — compose two formatted parts, don't concatenate raw letters.
6. Surface the active zone in the UI (footer or settings) so a user reading `14:03` knows whose `14:03` it is.
7. Sweep every consumer listed above for inline date formatting that bypasses `utils.ts`.

## Tests

- `frontend/src/utils.test.ts`: relative output in en/de/ja/ar for past and future at each unit boundary; `NaN`/`Infinity` → `'—'`; the week/month/year ladder.
- Timezone: fixed epoch renders differently under `America/New_York` vs `UTC` vs `Asia/Tokyo`; override beats browser zone; invalid stored zone falls back rather than throwing (`Intl` throws on a bad `timeZone`).
- DST boundary case — a timestamp inside the ambiguous hour formats without throwing.
- Live-tick: one timer per page, cleaned up on unmount (no leak — same discipline as the RAII pass in `docs/plans/2026/07/31/`).
- `bun run test` + `tsc -b`.

## Done when

- Relative times read naturally in all 8 shipped locales, including RTL.
- Absolute times render in the user's zone, with UTC still reachable.
- Zone is user-overridable and persists.
- Relative labels tick without a refetch, from one shared timer.
- No `toISOString()` or hand-rolled date math left outside `utils.ts`/`tz.ts`.
