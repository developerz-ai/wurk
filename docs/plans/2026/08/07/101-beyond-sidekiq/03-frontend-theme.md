# 03 — Theme system (light / dark / system)

> Part of [`overview.md`](overview.md). Depends on: none. Disjoint from backend slices.
>
> **Blocked on a maintainer call** — see "Decision" below. Everything else in the plan is independent of it.

## What exists

Dark-only, by explicit design:

| Anchor | State |
|---|---|
| `frontend/index.html:2` | `<html lang="en" data-theme="dark">` |
| `frontend/index.html:6-9` | `<meta name="color-scheme" content="dark">`, `theme-color` `#09090b`, **`<meta name="darkreader-lock">`** (stops Dark Reader washing it out) |
| `frontend/src/styles/abstracts/_tokens.scss:15-45` | Obsidian zinc palette declared **unlayered on bare `:root`** so it beats daisyUI's layered theme regardless of source order |
| `CLAUDE.md` (Dashboard §) · `docs/idea/08-dashboard.md` | "dark-only" is documented as a property of the design system |

The token layer is the right shape for theming — every colour is a CSS var on `:root`, no component hardcodes one (`_tokens.scss:1-6`). The work is a palette, not a refactor.

## Decision (get this before building)

Light mode is a **visual-identity change**, not a feature toggle. Obsidian was authored against a near-black canvas: "luminance over hue", 1px borders and no shadows, colour reserved for status signal only. A light palette has to re-derive that hierarchy — borders and tonal surfaces carry all the structure, and they invert badly.

Ask: ship light mode, or ship only "respect `prefers-color-scheme` for the *system* option and keep dark as the sole palette"? If the answer is dark-only, close this slice and keep the `darkreader-lock`.

## Files to change

- `frontend/src/styles/abstracts/_tokens.scss` — restructure: dark palette stays the `:root` default; add a light palette block.
- `frontend/index.html:2,6-9` — `data-theme` set by an inline pre-paint script; `color-scheme` → `light dark`; drop/condition `darkreader-lock`.
- `frontend/src/main.tsx:17-19` — theme applied alongside `dir`/`lang`, before render.
- new `frontend/src/theme.ts` — resolve, persist, subscribe to system changes.
- new `frontend/src/components/ThemeToggle.tsx` — three-state control (light / dark / system), next to `LocalePicker` (slice 02).
- `app/controllers/wurk/dashboard_controller.rb:41-51` — optional host-configured default theme, same injection point as slice 02's `data-locale`.
- Any component with a literal colour — audit; `_tokens.scss:1-6` claims there are none, verify rather than trust.

## Steps

1. Three-state model: `'light' | 'dark' | 'system'` in `localStorage["wurk.theme"]`, default `'system'`. `'system'` resolves via `matchMedia('(prefers-color-scheme: light)')` and **live-updates** on change (add the listener; don't resolve once at boot).
2. Apply as `data-theme="light|dark"` on `<html>` — the resolved value, never `system`.
3. **Pre-paint inline script** in `index.html` reading `localStorage` + `matchMedia` and stamping `data-theme` before the bundle loads. Without it every dark-mode user gets a white flash on each load. It must be inline (no import) and tiny.
4. Token structure — mirrors the Artifact/theme-aware convention:
   - bare `:root` — full dark palette (today's values, unchanged; keeps it the design default).
   - `:root[data-theme="light"]` — light overrides for the same var names only.
   - Do not define any colour solely inside a media query or a `[data-theme]` block; every var needs a value on bare `:root`.
5. Light palette derivation: invert luminance, don't invert hue. Canvas `#fafafa`-ish, surfaces stepping *down* in lightness, borders darker not lighter. Status colours (`--color-error/-warning/-success`) need re-picking for contrast on light — the current values are tuned for `#09090b` and will fail WCAG AA on white. Verify every text/background pair at AA.
6. `--color-scheme` meta + `theme-color` must track the resolved theme (mobile browser chrome).
7. `darkreader-lock` (`index.html:9`) — keep it only while a real light theme exists to switch to; otherwise Dark Reader users lose the light option. If light mode ships, remove it.
8. Charts: `frontend/src/components/charts/` — hand-rolled SVG. Confirm they read tokens, not literals (`charts/util.tsx` is the likely offender).

## Tests

- `frontend/src/theme.test.ts`: default `system`; explicit choice persists and wins over system; `matchMedia` change flips the resolved theme only in `system` mode; resolved value is never `'system'`.
- Component test: toggle cycles all three states, updates `documentElement.dataset.theme`.
- Visual check via `bin/rake frontend:build` + dummy app (`cd test/dummy && bin/rails s`) on both themes: dashboard, queues, retries, a chart page, a modal.
- Contrast audit at AA for every token pair in the light palette. Record the numbers in the PR.
- `bun run test` + `tsc -b`.

## Done when

- Light / dark / system all render correctly, no flash of the wrong theme on load.
- `system` tracks OS changes live without reload.
- Choice persists across reloads and across mounts.
- No component hardcodes a colour; charts follow the theme.
- AA contrast met in both palettes.
- `CLAUDE.md` Dashboard § and `docs/idea/08-dashboard.md` no longer say "dark-only" (slice 12 carries the docs).
