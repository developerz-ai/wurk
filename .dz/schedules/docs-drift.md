# Brief: where do the docs promise behaviour the code does not have?

Weekly scout, fired by `schedules: docs-drift` in `.dz/maintainer/maintainer.yml`. Wurk's docs are
part of the drop-in contract: a sentence the code does not implement is a promise the gem breaks.
The guard tests already police the claims they know about; this brief finds the ones they do not.

## What a finding is

Every finding carries these three things, in this order:

1. **Anchor** — `path:line` of the claim, e.g. `README.md:<line>`, plus the code anchor the claim
   contradicts, e.g. `lib/wurk/<file>.rb:<line>`.
2. **What is wrong** — one sentence naming the mismatch: the sentence says X, the code does Y.
3. **How to tell it is fixed** — the check that closes it: the doc line that must change (quoted as
   it stands) and the named guard test that goes green, e.g.
   `test/unit/readme_claims_test.rb:28`.

A finding missing any of the three is not reportable: report it as "doc drift, needs triage" and
say which one is missing.

## How to look

The surfaces: `README.md`, `CLAUDE.md`, `docs/**`, `docs/wiki/**`, `docs/site/llms.txt`.

The guard tests already policing claims on those surfaces — read them first and skip what they
own, so this lane never re-reports a claim a gate already covers:

| Guard | What it owns |
|---|---|
| `test/unit/readme_claims_test.rb:9` | README claims about a third-party gem's suite running in CI |
| `test/unit/docs_links_test.rb:15` | anchors and links between the reference docs |
| `test/unit/claude_md_claims_test.rb:13` | the same claims as the README, in CLAUDE.md |
| `test/unit/forbidden_claims_test.rb:12` | the pitch surfaces: README, docs site, llms.txt, the gem summary |
| `test/unit/cutover_claims_test.rb:12` | promises about running Sidekiq and Wurk against one Redis |
| `test/unit/wiki_pages_test.rb:13` | the docs/wiki/ pages: shape, links, duplication |
| `test/unit/llms_txt_test.rb:9` | docs/site/llms.txt: the format and the links it lists |
| `test/unit/site_code_blocks_test.rb:17` | keyboard reachability of the code snippets on the site |
| `test/unit/release_doc_claims_test.rb:14` | RELEASE.md's step table against release.yml |
| `test/unit/contributing_line_refs_test.rb:13` | CONTRIBUTING.md's `bin/check:<line>` references |
| `test/unit/spec_constants_test.rb:17` | the `Sidekiq::*` constants the specs name |

`RELEASE.md` is release tooling (see *Out of scope*), so the `release_doc_claims_test.rb` row is
listed to mark what that guard owns — this lane reports nothing there.

What the guards do not cover — the shapes of a drift no gate can see:

- A promise with no oracle: "always", "never", "all", "every", "100%", "drop-in" in a sentence no
  gate reads. Check the promise against the code, not against another doc.
- A number that moved: a version, a count, a threshold, a line reference.
- A command in a fenced block the repo does not ship (a `bin/...` path that does not exist).
- A doc describing a file that was renamed or deleted.

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

One ask per claim, with a stable title that names the surface and the promise — never the run it
was found in, because the dedupe below is an exact title match. The body carries the claim's
`path:line` anchor, the code anchor it contradicts, what is wrong, and how to tell it is fixed.

Before filing, run exactly:

```bash
gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'
```

the same lookup `.dz/briefs/health.md:171-180` uses — `gh issue list` truncates at 30 and cannot
paginate. If a returned title equals the ask's title exactly, the ask already exists: do not file
a second one.
