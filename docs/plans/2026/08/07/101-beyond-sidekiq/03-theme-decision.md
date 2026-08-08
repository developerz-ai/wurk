# Decision: Theme System (Slice 03)

**Decision:** Ship light / dark / system. Dark stays the design default.
**Date:** 2026-08-08 — supersedes the dark-only call recorded the same day (below).

## Current decision

Light mode ships. Dark remains the default and the design reference: it is the
bare-`:root` palette, so a document that never sets `data-theme` still renders
Obsidian exactly as authored. Light is an override block keyed on
`:root[data-theme="light"]`, and every var it touches already has a `:root`
value — nothing in the SPA depends on the light block existing.

The derivation rule is **invert luminance, not hue**. Obsidian's structure comes
from tone steps and 1px borders rather than shadows, so the whole ladder flips
direction: surfaces step *down* in lightness from the canvas, borders go *darker*
than what they separate, and `--shadow` stays `none` in both themes — elevation
is still edge, never blur.

The status trio is re-picked rather than reused. The dark values sit around
OKLCH L 0.70–0.78 and land near 1.4:1 on a white canvas. The light values hold
the same hues at L≈0.47:

| Token | Dark | Light | Hue held | Light on canvas | Light on 16% badge fill |
|---|---|---|---|---|---|
| `--color-error` | `#f0786f` | `#a32224` | 25.9° → 25.7° | 7.16 | 5.18 |
| `--color-warning` | `#d8b34a` | `#715700` | 89.5° → 88.5° | 6.56 | 4.95 |
| `--color-success` | `#3fb950` | `#0f6b23` | 145.6° → 145.9° | 6.39 | 4.78 |

Amber is chroma-capped by sRGB at that lightness — dark gold is as saturated as
an AA-passing yellow gets.

`darkreader-lock` (`frontend/index.html:10`) comes out once the toggle ships: it
exists to stop Dark Reader washing out a UI with no light option, and that is no
longer the situation.

## Superseded: dark-only (2026-08-08)

The original call was to ship dark-only, on the grounds that light mode is a
visual-identity change rather than a palette swap — Obsidian was authored
against a near-black canvas, and re-deriving the hierarchy for a light canvas is
a redesign. `CLAUDE.md` (Dashboard §) and `docs/idea/08-dashboard.md` line 9
both declared the dashboard dark-only, and `frontend/index.html` already shipped
`data-theme="dark"`, `color-scheme="dark"` and `darkreader-lock`.

That reasoning is why the light palette is derived the way it is rather than by
flipping a switch — the redesign concern was real, it was answered by doing the
derivation deliberately (luminance ladder inverted, status colours re-picked and
contrast-audited) instead of by dropping the feature.

Reversed. Slice 03 proceeds; tasks 20–23 are in scope.

## Task 23 — full-palette AA contrast audit (light theme)

WCAG 2.1 relative-luminance contrast, every foreground token against both
surfaces it actually sits on (`--bg` = `--color-base-100` and
`--surface` = `--color-base-200`). AA text threshold is 4.5:1 (3:1 for
large/bold text and non-text UI components).

| Token | On canvas (`#fafafa`) | On card (`#f4f4f5`) | Verdict |
|---|---|---|---|
| `--color-base-content` / `--mono-1` / `--accent` (text) | 16.97:1 | 16.12:1 | AA |
| `--mono-1` (`#09090b`) | 19.06:1 | 18.10:1 | AA |
| `--mono-2` (`#27272a`) | 14.27:1 | 13.55:1 | AA |
| `--mono-3` / `--text-muted` (`#52525b`) | 7.41:1 | 7.03:1 | AA |
| `--mono-4` (`#71717a`) | 4.63:1 | 4.40:1 | AA (AA-large on card) |
| `--mono-5` (`#a1a1aa`) | 2.46:1 | 2.33:1 | Below AA — decorative-only (see below) |
| `--mono-6` (`#d4d4d8`) | 1.42:1 | 1.34:1 | Below AA — decorative-only |
| `--series-1` (`#836400`) | 5.31:1 | 5.04:1 | AA |
| `--series-2` (`#007a71`) | 5.00:1 | 4.75:1 | AA |
| `--series-3` (`#aa3f50`) | 5.69:1 | 5.40:1 | AA |
| `--series-4` (`#6858b3`) | 5.53:1 | 5.26:1 | AA |
| `--series-5` (`#0471a0`) | 5.19:1 | 4.93:1 | AA |
| `--series-6` (`#97561e`) | 5.49:1 | 5.21:1 | AA |
| `--series-7` (`#3b7a34`) | 5.01:1 | 4.75:1 | AA |
| `--color-error` | 7.16:1 | 6.80:1 | AA |
| `--color-warning` | 6.56:1 | 6.23:1 | AA |
| `--color-success` | 6.39:1 | 6.07:1 | AA |
| `--accent-hover` (`#000000`) | 20.12:1 | 19.11:1 | AA |
| `--color-primary-content` on `--color-primary` | 16.97:1 | — | AA |
| `--color-error-content` on `--color-error` | 7.16:1 | — | AA |
| `--color-warning-content` on `--color-warning` | 6.56:1 | — | AA |
| `--color-success-content` on `--color-success` | 6.39:1 | — | AA |

Every token used for body text, headings, links, series legends, and status
badges clears AA (4.5:1) on both surfaces the SPA renders it against;
`--mono-4` clears AA on canvas and AA-large on card, matching its one use as
bold/emphasized secondary text.

`--mono-5` and `--mono-6` fall under both the 4.5:1 text and the 3:1
non-text-UI thresholds on a light canvas — by design, not oversight. They're
the two faintest rungs of the ink ladder, and the ladder is defined to
*decrease* contrast against the canvas at each step (`_tokens.scss:41-44`).
Their only consumers are graduated-intensity indicators, not text or
essential UI boundaries: the `JOB_DOTS` ranking dots in `Metrics.tsx` (rank 5
and 6 of 6, where the fade itself communicates "lowest") and the below-peak
bars in the queue-depth `BarChart` (`Metrics.tsx:350`, where the peak bar is
`--mono-1` and every other bar is intentionally recessive). Both convey
secondary/redundant information — rank order and peak-vs-not are also given
by position and by the bar's own height/label — so the WCAG AA gate doesn't
apply, and re-picking them to clear 3:1 would flatten the ladder's fifth and
sixth steps into the fourth, defeating the point of a 6-step ladder. Confirmed
by walking every call site (`grep -rn 'mono-5\|mono-6'`); no text or
essential-boundary use exists on either theme.
