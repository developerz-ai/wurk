# 12 — Docs, site, README, llms.txt

> Part of [`overview.md`](overview.md). Depends on: whichever slices actually shipped. **Run last.** Document only what landed — a doc for a deferred slice is worse than no doc.

## Rule

Every slice above is a **Wurk extra**, not Sidekiq parity. Docs must say so plainly, so a migrant can tell "this is the drop-in surface" from "this is Wurk-only, and using it ties you to Wurk". `docs/target/sidekiq-{free,pro,ent}.md` stay untouched — they are the parity spec, not a feature list.

## Files to change

| File | Change |
|---|---|
| new `docs/api-http.md` | slice 07: full route reference, **all three mount modes**, auth/scopes, error shapes, client examples. Written with the code, not after. |
| new `docs/telemetry.md` | slice 05: setup, span/attribute names, retry + long-delay semantics |
| new `docs/job-status.md` | slice 06: opt-in, API, retention, size caps, encryption interaction |
| new `docs/flows.md` | slice 11: DAG + chains, failure propagation, limits |
| `docs/unique-jobs.md` | slice 09: debounce + throttle policies; also document the existing `sidekiq_unique_context` hook (`lib/wurk/unique.rb:36-44`) — it's the supported "unique by arg subset" path and is currently undocumented |
| `docs/retries.md` | slice 08: timeout/deadline in the failure lifecycle |
| `docs/rate-limiting.md` | slice 10: global per-queue concurrency vs. the per-key limiters — say clearly which to reach for |
| `docs/dashboard.md` | slices 02–04: theme, locale override, timezone |
| `docs/configuration.md` | every new option, in the existing precedence table format |
| `docs/metrics.md` | slice 01: what an interrupted run does and does not book |
| `docs/idea/parity-divergences.md` | slice 01 outcome; any job-JSON key added by 05/06/08 |
| `docs/idea/13-roadmap.md` | fold the shipped items into the roadmap; the "Stretch (post-1.0)" list is stale |
| `README.md` | feature matrix — add a **"Wurk extras"** section distinct from the Sidekiq-tier table |
| `CLAUDE.md` | Dashboard § still says "dark-only" — only if slice 03 shipped |
| docs site (`docs/site/`) + wiki | mirror README; the site is published from here |
| `llms.txt` | the machine-readable map — new features must appear or agents won't find them |
| `CHANGELOG.md` | `[Unreleased]`, one entry per shipped slice, behavior changes called out |

## Steps

1. Inventory what actually landed. Check `status.yml` in this plan dir, not memory.
2. For each shipped slice, write its doc page **before** touching README/site — the deep page is the source, the summaries link to it.
3. Mark every extra as Wurk-only, with a one-line "what you give up if you migrate back to Sidekiq".
4. **`CLAUDE.md` pillar 3 — no "faster than Sidekiq" claim anywhere.** This has been violated before, in `spec.summary` (published on the RubyGems page), the dashboard tagline in all 8 locales, and the site. Grep the whole repo — `README.md`, `wurk.gemspec`, `frontend/src/i18n/*.json`, `docs/site/`, `llms.txt`, `frontend/index.html` meta descriptions — before publishing. Wurk is 0.87×–1.02× (`docs/benchmarks.md`).
5. Regenerate YARD for any new public class (`Wurk::Status`, `Wurk::Flow`, `Wurk::API`) and confirm the `Sidekiq::*` alias table in the README is still accurate.
6. Re-run the doc-link check if one exists; otherwise spot-check every new link. The README is dense with links and a dead one ships in the gem.

## Tests

- `bin/rake test` (docs changes can break the engine's asset/manifest expectations if `docs/site` shares tooling).
- Build the site locally; check new pages render and nav includes them.
- `bin/rake release:check` — the tag ↔ `Wurk::VERSION` ↔ CHANGELOG gate. It has failed silently twice (v1.2.1, v1.5.0); run it before assuming a release is publishable.
- Grep gate: zero "faster" claims outside `docs/benchmarks.md`'s measured context.

## Done when

- Every shipped slice has a docs page, linked from README and the site.
- Extras are unambiguously distinguished from parity surface.
- `llms.txt` and the YARD reference cover the new public classes.
- CHANGELOG `[Unreleased]` complete, behavior changes flagged.
- No unsupported performance claim anywhere in the repo, gem metadata, dashboard copy, or site.
