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

## Guards already policing these claims

Check these before reporting: a claim a guard owns is not a finding.

- **Behavior oracles** — `test/parity/**/*_test.rb`, run by `bin/rake test:parity`
  (Rakefile:69-76); the oracle rule is test/parity/README.md:11. Within the cases.yml
  entries that cite them, these are the only guards whose green proves Wurk behaves
  as the documented surface does; documented-surface behaviour no case cites is owned
  by other guards or stays reportable (e.g. test/unit/compat_aliases_test.rb:41-44).
- **Conformance gate** — `test/conformance/**` in the same `test:parity` run
  (Rakefile:69-76), inventory `test/conformance/cases.yml`. Static quotation, not
  behaviour: green proves the case's verbatim `promise` still exists, normalized, at
  its source anchor (test/support/conformance.rb:164-171), that the anchor resolves
  to non-blank doc lines (:128-147), and that a ledger range spans its entry's `##`
  heading (:173-183). Registration (test/support/conformance.rb:37-51) additionally
  requires every cited oracle to be runnable and every `test/parity/` oracle class
  to be cited by some case or exempted (:13-15; only `IterableJobStateParityTest`).
  It asserts no behaviour itself: a covered case passes only by replaying the parity
  oracles its `oracles:` cites (test/support/conformance.rb:260-262). Pending
  entries (reason + future_work, no oracles) run only as skipped
  ConformancePendingTest stubs (test/support/conformance.rb:283-289) — they prove
  nothing and stay reportable. cases.yml:1: one sourced guarantee per entry, never
  complete coverage, so spec behaviour with no cases.yml entry stays reportable.
- **Require shim** — test/unit/compat_aliases_test.rb:5-8 owns the `Sidekiq::*`
  drop-in surface (spec §3); Pro/Ent sentinels at :34-37 and :77-80. It partially
  owns cases.yml:918-943 (module.pro-flag, module.ent-flag): the false `pro?`/`ent?`
  return is guarded (:85-91); the upstream namespace-presence promise stays pending
  (oracle-module-pro-flag, oracle-module-ent-flag) and reportable.
- **Spec docs** — test/unit/spec_docs_test.rb:18 checks only that
  docs/target/sidekiq-{free,pro,ent}.md exist and are non-empty: no line wording is
  pinned, so spec drift stays reportable.

Ledger anchors are the narrowest coverage of all: only the six
docs/idea/parity-divergences.md ranges cases.yml quotes (cases.yml:269, :397, :441,
:450, :563, :654) are quotation-guarded. Every other ledger entry's anchor has at
most a link-shape guard: DocsLinksTest checks that a ledger link's target file exists
and its `#L` range falls inside it (test/unit/docs_links_test.rb:204-217; link form
at docs/idea/parity-divergences.md:108-110); whether the anchored code has moved is
guarded by nothing, so a moved anchor there is a finding. A plain backticked
`path:line` anchor, not a markdown link, is guarded by nothing at all.

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

the same lookup the filing rule in `.dz/briefs/health.md` runs — `gh issue list` truncates at 30
and cannot paginate. If a returned title equals the ask's title exactly, the ask already exists:
do not file a second one.
