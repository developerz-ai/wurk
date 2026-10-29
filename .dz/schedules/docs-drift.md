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
own, so this lane never re-reports a claim a gate already covers. The registry below is that list:
one row per guard, the anchor it lives at, and the claim it owns. The ask slug is the stable title
that claim carries. A new guard is a change to this brief, never a row invented at reporting time.

## Guard registry

A guard qualifies for this registry when it is a test class under `test/unit/` that reads a documentation surface — `README.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `RELEASE.md`, or a file under `docs/`. Ownership is per claim: a guard that owns one claim on a surface owns no other claim on it, and this lane keeps reporting the claims no guard owns.

| Ask slug | Guard anchor | Guard class | Claim it owns |
|---|---|---|---|
| `readme-third-party-ci-claims` | `test/unit/readme_claims_test.rb:9` | `ReadmeClaimsTest` | README.md's claim that a `sidekiq-*` gem's suite runs in CI |
| `docs-links-anchors` | `test/unit/docs_links_test.rb:26` | `DocsLinksTest` | the anchors between the reference docs: every intra-doc link must resolve to a heading that exists |
| `docs-divergence-table` | `test/unit/docs_links_test.rb:379` | `DocsDivergenceTableTest` | the `## Divergences from the Sidekiq spec` table against the ledger in docs/idea/parity-divergences.md |
| `docs-env-table-complete` | `test/unit/docs_links_test.rb:568` | `DocsEnvTableTest` | docs/configuration.md's "Every `ENV` read in `lib/`" claim — the env table staying complete |
| `deployment-bun-docker-pin` | `test/unit/toolchain_pins_test.rb:13` | `ToolchainPinsTest` | docs/deployment.md's `oven/bun` example Dockerfile pin — present and identical to the other pin sites |
| `claude-md-claims` | `test/unit/claude_md_claims_test.rb:13` | `ClaudeMdClaimsTest` | CLAUDE.md's claim that a `sidekiq-*` gem's suite passes against Wurk |
| `forbidden-pitch-claims` | `test/unit/forbidden_claims_test.rb:18` | `ForbiddenClaimsTest` | the pitch claims on README.md, the docs site and llms.txt: "faster", published scale figures, a per-job progress surface |
| `cutover-shared-redis-claims` | `test/unit/cutover_claims_test.rb:12` | `CutoverClaimsTest` | promises about running Sidekiq and Wurk against one Redis |
| `wiki-pages-shape` | `test/unit/wiki_pages_test.rb:13` | `WikiPagesTest` | the docs/wiki/ pages: shape, links, duplication |
| `llms-txt-format-links` | `test/unit/llms_txt_test.rb:9` | `LlmsTxtTest` | docs/site/llms.txt: the format and the links it lists |
| `site-code-block-keyboard` | `test/unit/site_code_blocks_test.rb:21` | `SiteCodeBlocksTest` | keyboard reachability of the code snippets on the site |
| `release-doc-steps` | `test/unit/release_doc_claims_test.rb:19` | `ReleaseDocClaimsTest` | RELEASE.md's step table against release.yml |
| `release-states-table` | `test/unit/release_states_doc_test.rb:19` | `ReleaseStatesDocTest` | RELEASE.md's `### Release states` table — one row per release state |
| `contributing-line-refs` | `test/unit/contributing_line_refs_test.rb:13` | `ContributingLineRefsTest` | CONTRIBUTING.md's `bin/check:<line>` references |
| `spec-named-constants` | `test/unit/spec_constants_test.rb:17` | `SpecConstantsTest` | the `Sidekiq::*` constants the specs name |
| `spec-require-shims` | `test/unit/sidekiq_require_shims_test.rb:16` | `SidekiqRequireShimsTest` | the `require "sidekiq…"` paths the specs document — each must resolve to a Wurk shim |
| `llms-full-dump` | `test/unit/llms_full_test.rb:12` | `LlmsFullTest` | the generated llms-full dump: every top-level doc inlined verbatim, none unaccounted for |

The two `RELEASE.md` rows are release tooling (see *Out of scope*), so they are listed to mark what
those guards own — this lane reports nothing there.

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

the same lookup the filing rule in `.dz/briefs/health.md` runs — `gh issue list` truncates at 30
and cannot paginate. If a returned title equals the ask's title exactly, the ask already exists:
do not file a second one.
