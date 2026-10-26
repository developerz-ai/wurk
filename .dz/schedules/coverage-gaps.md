# Brief: where is the coverage thin?

Weekly scout, fired by `schedules: coverage-gaps` in `.dz/maintainer/maintainer.yml`. The coverage
gate is a floor, not a map. `lib/` is tracked in full, so a file no test requires counts as 0%
instead of dropping out of the denominator — but a file at 91% whose failure branch no test reaches
still passes the gate. This brief finds the code the global number hides. It also permits
inspection and filing of frontend contract/error-path coverage gaps under `frontend/src/`.

## What a finding is

Every finding carries these three things, in this order:

1. **Anchor** — `path:line` of the uncovered code, e.g. `lib/wurk/<file>.rb:<line>`.
2. **What is wrong** — one sentence naming the mismatch: which behaviour has no oracle, or which
   branch no test reaches.
3. **How to tell it is fixed** — the check that closes it: the named test that goes green, the
   per-file line/branch percentage in the Cobertura report that has to move, or the branch that has
   to appear.

A finding missing any of the three is not reportable: report it as "thin coverage, needs triage"
and say which one is missing.

## How to look

### Ruby coverage

- The gate is configured at test/test_helper.rb:3-19 — branch coverage on (:10), line coverage
  primary (:11), `lib/**/*.rb` tracked (:16), `minimum_coverage line: 90, branch: 90` (:17). Both
  numbers are blocking, and both are global.
- The per-file numbers are in the Cobertura report the coverage run leaves at
  `coverage/coverage.xml`, uploaded by CI as the `coverage` artifact
  (.github/workflows/test.yml:223-228). Read a file's own row, never the total.
- The total is only real when the merge was complete: test/support/coverage_merge.rb:49 aborts a
  run whose merge lost a forked worker's resultset (`coverage merge incomplete: missing worker-N`).
  The abort follows `SimpleCov.running = false` (:48), so SimpleCov's at-exit hook does nothing:
  that run writes no report and prints no percentage. Nothing may be quoted from it — read the
  report a complete run produced.
- `bin/rake test:coverage` (Rakefile:83-87) is how the gate is run. This lane does not run it: a
  coverage run flushes the test Redis DBs, and this lane must not mutate Redis data. Read the
  report a run already produced.

Two shapes of gap, in the order they are worth reporting:

1. **No test at all.** A `lib/` file that no test requires. `track_files` counts it as 0%, so it
   drags the total while never appearing in a test run.
2. **A branch never taken.** High line coverage, low branch coverage on the same file: a `rescue`
   arm, a fallback, a flag only ever exercised at its default. The branch minimum is global, so a
   file can sit at 91% branch with its failure path never run.

### Frontend contract/error-path coverage

Inspect frontend source and existing tests, and file concrete contract/error-path gaps. Every
frontend finding must include:

- A source `path:line` anchor under `frontend/src/`.
- Concrete behavioral evidence: the input or failure condition, the expected contract, and the
  behavior or error path that existing tests do not assert. Missing tests alone are insufficient.
- Relevant existing or proposed repository test paths (`frontend/src/**/*.test.{ts,tsx}`),
  identifying which test to extend or where to add an oracle.
- A specific closing assertion: state exactly what the test must assert for that condition.

Frontend findings are not measured by Ruby SimpleCov or Cobertura. Do not infer frontend
percentages or coverage gates from Ruby reports; use frontend contract/test evidence instead.
The Ruby global 90% line/branch floors do not apply to frontend findings. Inspect only: do not
run tests or generate coverage in this read-only lane.

## Read-only

This lane reads and reports. It never edits a file, commits, pushes, opens a pull request, or runs
a command that mutates the repo, its Redis data or CI.

## Out of scope

- CI configuration: `.github/workflows/**`.
- The maintainer policy file: `.dz/**`, including this directory (`.dz/schedules/`) and
  `.dz/maintainer/maintainer.yml`.
- Release tooling: `RELEASE.md`, `lib/wurk/version.rb`, `tasks/release_helpers.rb`, `bin/gem-*`, the
  `release:` rake tasks, `.github/workflows/release.yml`.

A gap in any of those is not this lane's finding: do not report it, and do not edit it.

## Reporting

One ask per file, never one per gap — the gaps of one source file travel together. Use the
file's path without the line number as the title, for example:

- `Coverage gap: lib/wurk/<file>.rb`
- `Coverage gap: frontend/src/<file>.ts`
- `Coverage gap: frontend/src/components/<file>.tsx`

The body carries each gap's `path:line` anchor, what is wrong, and how to tell it is fixed.
For frontend gaps include the required behavioral evidence, test paths and closing assertion;
for Ruby gaps retain the per-file Cobertura evidence above. The title must not change between
runs: the dedupe below is an exact title match.

Before filing, run exactly:

```bash
gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'
```

the same lookup the filing rule in `.dz/briefs/health.md` runs — `gh issue list` truncates at 30
and cannot paginate. If a returned title equals the ask's title exactly, the ask already exists:
do not file a second one.
