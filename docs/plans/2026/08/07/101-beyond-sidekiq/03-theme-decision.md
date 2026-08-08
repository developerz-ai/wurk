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
