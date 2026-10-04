# 01 — Repo hygiene + doc truth

> Part of [`overview.md`](overview.md). Depends on: none. Do first (minutes).

## Files to change

| ID | Where | Problem | Fix |
|---|---|---|---|
| H1 | `docs/target/sidekiq-{free,pro,ent}.md` | Deleted in the working tree (unstaged) as of 2026-10-04. They are the authoritative spec (CLAUDE.md "Authoritative spec") and the parity oracle source; `test/unit/spec_docs_test.rb` + `spec-docs` job (`.github/workflows/test.yml:284`) fail without them. **Recurrence:** cf4b25f (#316) added `spec_docs_test` because the same thing happened before; the culprit (an agent/tool) is unknown. | `git checkout -- docs/target`. Then make deletion un-mergeable: [`05`](05-ci-gates.md) C1/C2. Investigate the culprit: grep agent configs/hooks/scripts for `docs/target` or `rm -rf docs` (`.dz/`, `.claude/`, `bin/`, `tasks/`). |
| H2 | `CLAUDE.md:33` | Release row says `bin/rake release` (Bundler tag+push). | Fixed in [`06`](06-release-lane.md). |
| H3 | `CLAUDE.md` pillar 3 | ">5% … blocks merge" — `bench vs base` not required (`bench.yml:29`). | Reword (or require — HITL). [`05`](05-ci-gates.md) C12. |
| H4 | `CLAUDE.md:100` | Bench-runner + fork-PR claims overstate. | [`10`](10-infrastructure.md) I6. |
| H5 | `.dz/maintainer/maintainer.yml:70-73,95,117` | Stale claims (#488). | [`11`](11-human-actions.md) / issue map. |
| H6 | `test.yml:98-101`, `bin/check:13` | "4 workers" comments stale since #536. | [`05`](05-ci-gates.md) C10. |
| H7 | `docs/migrate-from-sidekiq.md:366-369,452-461` | Ecosystem ✅ claims false; shim gem undocumented. | [`09`](09-production-readiness.md) R5. |
| H8 | README "millions of jobs an hour" | Unbacked by published data. | Qualify until R11 soak numbers exist. |

## Steps
1. H1 restore now; commit nothing else in that PR.
2. Add forbidden-claim test coverage beyond wiki: extend `test/unit/wiki_pages_test.rb:28`-style check ("faster") to `README.md`, `docs/site/llms.txt`, `docs/site/index.html`, gemspec summary (CI audit P2-9).
3. Remaining H* land with their owning slices.

## Tests
- `bin/rake test TEST=test/unit/spec_docs_test.rb`.
- New forbidden-claim test fails if "faster than sidekiq" appears in any listed file.

## Done when
- `git status` clean of spec deletions; `spec-docs` green; culprit identified or noted as unknown in this slice's PR body.
