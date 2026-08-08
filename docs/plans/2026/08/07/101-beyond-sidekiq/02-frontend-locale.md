# 02 — Locale auto-detect + user override

> Part of [`overview.md`](overview.md). Depends on: none. Disjoint from backend slices — safe to run in parallel.

## What exists

`frontend/src/i18n/index.ts`:
- `detectLocale()` — reads `#wurk-root[data-locale]`, falls back to `navigator.language`, then `'en'`.
- `directionFor()` + `RTL_LANGS` — `ar`/`he`/`fa` → `dir="rtl"`.
- `loadHostOverrides()` — reads `#wurk-i18n` JSON `<script>` for host copy overrides.
- Bundles: `en es fr de pt-BR ja zh-CN ar`. `langKey` match is `locale.startsWith(k)`.
- `frontend/src/main.tsx:18-19` sets `document.documentElement.dir` / `.lang` before first paint; `:31` mirrors `dir` onto the root node.

So auto-detect **is already there**. Three real gaps:

| Gap | Evidence |
|---|---|
| `data-locale` and `#wurk-i18n` are **never emitted by the engine** — the documented host-override path is unwired | `grep -rn "wurk-i18n\|data-locale" --include=*.rb` → no hits. `dashboard_controller.rb#index` injects only `window.__WURK_BASE__` (`:41-51`) |
| No user-visible override — a browser set to `de` can't view the board in `en` | no picker anywhere in `frontend/src/components/` |
| `startsWith` match is wrong-way-round for regional tags | `locale = "pt"` matches key `"pt-BR"`? No — `"pt".startsWith("pt-BR")` is false, so `pt` falls back to `en` instead of `pt-BR`. `"es-419"` → matches `es` correctly. Asymmetric. |

## Files to change

- `frontend/src/i18n/index.ts` — `detectLocale()` precedence chain; fix bundle matching; export `setLocale()`/`availableLocales`.
- `frontend/src/main.tsx:18-19` — unchanged behavior, but locale now comes from the resolved chain.
- `frontend/src/components/` — new `LocalePicker.tsx`, mounted in the left-rail/settings area (see `layout/` SCSS + existing nav component).
- `app/controllers/wurk/dashboard_controller.rb:41-51` — emit `data-locale` on `#wurk-root` from `Accept-Language` (and any host-configured default), alongside the existing base-script injection. Same `js_string`-style escaping discipline.
- `lib/wurk/web/config.rb` — host-settable default locale + allowed-locale list.
- `frontend/src/i18n/i18n.test.ts` — extend.

## Steps

1. Precedence chain in `detectLocale()`, highest first:
   1. `?locale=` query param (one-off, not persisted) — useful for support/debug.
   2. `localStorage["wurk.locale"]` — the user's explicit pick.
   3. `#wurk-root[data-locale]` — host/server hint (new, from `Accept-Language`).
   4. `navigator.languages[]` — walk in order, first with a bundle wins (today only `navigator.language`).
   5. `'en'`.
2. Fix bundle matching: normalize to lowercase, try exact key, then base subtag → best regional bundle (`pt` → `pt-BR`, `zh` → `zh-CN`). Keep the existing "no bundle still flips RTL and falls back to en strings" behavior — it's deliberate (comment at `index.ts:22-27`).
3. `setLocale(loc)` — persist to `localStorage`, update `document.documentElement.lang`/`dir` and `#wurk-root.dir`, then reload. Full reload is acceptable and simpler than making `t()` reactive; `merged` is computed once at module scope by design.
4. `LocalePicker` — lists `availableLocales` with endonyms (Deutsch, 日本語, العربية), current marked. Keyboard-navigable, labeled for screen readers.
5. Engine side: parse `Accept-Language` (quality-ordered), intersect with the shipped locale list, emit as `data-locale`. Never trust it as markup — attribute-escape.
6. Document `#wurk-i18n` host-override emission while in here — it's referenced by `loadHostOverrides()` but nothing produces it. Either wire it from a host-configurable hash in `Wurk::Web.config`, or delete the dead path. Don't leave it half-real.

## Tests

- `frontend/src/i18n/i18n.test.ts`: precedence order (all five levels), `pt` → `pt-BR`, `zh` → `zh-CN`, `es-419` → `es`, unknown locale → en strings + correct `dir`, RTL for `he`/`fa` without bundles, `setLocale` persists.
- Component test: picker renders every locale, click calls `setLocale`.
- Engine test: `Accept-Language: de-DE,de;q=0.9,en;q=0.8` → `data-locale="de"`; unknown language → no attribute (SPA falls through to `navigator.languages`); header injection attempt is escaped.
- `bun run test` + `tsc -b` in `frontend/`; `bin/rake test TEST=test/engine/dashboard_controller_test.rb`.

## Done when

- A user can override the detected language from the UI and it survives reload.
- `Accept-Language` picks the right bundle on first paint (no flash of English).
- `pt` and `zh` resolve to their regional bundles.
- `#wurk-i18n` is either emitted by the engine or removed.
- RTL behavior unchanged for `ar`/`he`/`fa`.
