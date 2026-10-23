# Brief: where does Wurk drift from the documented Sidekiq surface?

Weekly scout, fired by `schedules: sidekiq-parity` in `.dz/maintainer/maintainer.yml`. Wurk is a
drop-in replacement, so the documented Sidekiq surface is the contract and the parity oracles are
the tests that enforce it. This brief finds the drift the oracles do not cover, and the recorded
divergences whose anchors have moved.

## What a finding is

Every finding carries these three things, in this order:

1. **Anchor** — `path:line` of the Wurk code that drifts, e.g. `lib/wurk/<file>.rb:<line>`, plus
   the spec anchor it drifts from, e.g. `docs/target/sidekiq-free.md:<line>`.
2. **What is wrong** — one sentence naming the mismatch: the spec says X, Wurk does Y.
3. **How to tell it is fixed** — the check that closes it: the named parity oracle that goes green
   (`bin/rake test:parity`), the spec line that must change, or the ledger entry that must be
   added or corrected.

A finding missing any of the three is not reportable: report it as "parity drift, needs triage"
and say which one is missing.

## How to look

- The spec is authoritative: `docs/target/sidekiq-free.md` (OSS surface; the target version at :3,
  the goal at :5, the canonical key schema at :11), `docs/target/sidekiq-pro.md` and
  `docs/target/sidekiq-ent.md`. A behaviour written down there and not implemented is a finding; a
  behaviour not written down is not a contract.
- The oracles live in `test/parity/` and run with `bin/rake test:parity` (Rakefile:69-76). They
  are independently written, not copies of upstream Sidekiq's test files, and they are oracles:
  when Wurk diverges from one, Wurk is wrong unless the divergence is documented as intentional
  (test/parity/README.md:11).
- The pinned upstream revision is test/parity/.sidekiq_sha:6 — sha
  `e1f808a08645f9b8a194852a171b5667f5f877bd`, dated 2026-08-03. A behaviour that moved upstream
  after that pin is a finding against the pin, not against Wurk.
- The recorded divergences are the ledger `docs/idea/parity-divergences.md`. Each entry states what
  Wurk does, what the spec says, why the divergence is safe, and the anchor to revisit
  (docs/idea/parity-divergences.md:7-10). Two findings live here:
  1. a divergence Wurk now implements but the ledger still describes as undecided;
  2. an entry whose anchor has moved — the cited `path:line` no longer holds the code it pointed
     at, so the ledger sends a reader to the wrong line.

This lane does not run the parity suite: it uses the test Redis DBs, and this lane must not mutate
Redis data. Name the oracle that has to go green; the lane that owns the suite runs it.

## Read-only

This lane reads and reports. It never edits a file, commits, pushes, opens a pull request, or runs
a command that mutates the repo, its Redis data or CI.

## Out of scope

- CI configuration: `.github/workflows/**`.
- The maintainer policy file: `.dz/**`, including this directory (`.dz/schedules/`) and
  `.dz/maintainer/maintainer.yml`.
- Release tooling: `RELEASE.md`, `lib/wurk/version.rb`, `tasks/release_helpers.rb`, `bin/gem-*`, the
  `release:` rake tasks, `.github/workflows/release.yml`.

A drift in any of those is not this lane's finding: do not report it, and do not edit it.

## Reporting

One ask per drift, with a stable title that names the surface and the divergence — never the run it
was found in, because the dedupe below is an exact title match. The body carries the code anchor,
the spec anchor, what is wrong, and how to tell it is fixed.

Before filing, run exactly:

```bash
gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'
```

the same lookup `.dz/briefs/health.md:171-180` uses — `gh issue list` truncates at 30 and cannot
paginate. If a returned title equals the ask's title exactly, the ask already exists: do not file
a second one.
