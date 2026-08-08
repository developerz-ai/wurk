# Decision: Dark-Only Theme (Slice 03)

**Date:** 2026-08-08  
**Decision:** Ship dark-only. Do not implement light mode.

## Rationale

The dashboard was designed dark-first against a near-black canvas (`#09090b`). The visual hierarchy relies on "luminance over hue": 1px borders and no shadows carry structural weight, colour reserved purely for status signal.

Implementing light mode would require re-deriving this entire hierarchy — tonal surfaces replacing borders, different shadow treatment, completely re-picked status colours for contrast on white. This is not a palette swap; it's a redesign.

## Outcome

- Close slice 03 (theme system) as complete.
- Keep `<meta name="darkreader-lock">` in `frontend/index.html:10` so Dark Reader users cannot accidentally un-invert a cohesively dark UI.
- Do not implement theme toggle, theme picker, or theme runtime.
- Do not restructure `_tokens.scss` into light/dark branches.
- Do not write theme tests or contrast audits.
- Skip tasks 20–23 of the "Theme system" group (all theme-implementation tasks).

## References

- `CLAUDE.md` Dashboard § (line 107): "dark-only, mobile-first, i18n" — documented as a property of the design system.
- `docs/idea/08-dashboard.md` § "Look and feel" (line 9): "Dark-only theme. A single cohesive dark theme (no light toggle), with a data viz palette tuned for accessibility."
- `frontend/index.html:2,6-10` — all existing markup already reflects dark-only (data-theme="dark", color-scheme="dark", darkreader-lock present).

## No Code Changes Required

This is a documented decision, not an implementation. The codebase already implements the dark-only choice perfectly. No palette work, no tests, no theme picker — just close the decision.
