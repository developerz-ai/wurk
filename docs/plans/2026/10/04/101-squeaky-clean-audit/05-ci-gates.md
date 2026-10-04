# 05 — CI gates (closes #469, #541, #470)

> Part of [`overview.md`](overview.md). Depends on: none. Do first — every later PR rides these gates. Source: CI audit + issue research 2026-10-04.

Baseline (verified clean): no `tags:` trigger; `vars.WURK_CI_RUNNER` / `vars.WURK_BENCH_RUNNER` spelled right at every site; fork guard first on every var-runner job; every job has `timeout-minutes`; every workflow has `concurrency`; deploy/pages/release/wiki `cancel-in-progress: false`. Main `test`/`ecosystem` green since 2026-09-07.

## Findings

| ID | Sev | Where | Defect | Fix |
|---|---|---|---|---|
| C1 | P1 | `.github/workflows/test.yml:53-73` (`ruby` paths-filter) | Docs-guard tests (`readme_claims_test`, `llms_txt_test`, `claude_md_claims_test`, `contributing_line_refs_test`, `docs_links_test`, `site_code_blocks_test`, `llms_full_test`, `spec_docs_test`, `bench_*`) read `README.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `docs/*.md`, `docs/site/**`, `docs/target/**`, `bench/**`, `CHANGELOG.md` — none in filter → docs-only PR green without running them. | Add those paths + `.rubocop.yml` (C3). |
| C2 | P1 | `test.yml:272-294` (`spec-docs`) | Not a required check; PR deleting `docs/target/*.md` merges (exactly the current local working-tree state — see [`01`](01-repo-hygiene.md)). | Covered by C1 (`docs/target/**` in filter) **and** make `spec docs` required (HITL, [`11`](11-human-actions.md)). |
| C3 | P1 | `test.yml:53-73` | `.rubocop.yml` / `bench/**` changes skip lint. | Add to filter. |
| C4 | P1 = #469 | `test.yml:238` (parity), `test.yml:356` (lint) | Job-level `if:` → skipped = passing. | Per-step pattern from `test` job (`test.yml:131`): drop job `if:`, `env: RUN: ${{ github.event_name != 'pull_request' \|\| needs.detect.outputs.ruby == 'true' }}`, `if: env.RUN == 'true'` on each step. Same for `spec-docs` (`:275`), `frontend` (`:394`). Fix the wrong comment at `test.yml:127-131`. |
| C5 | P1 | `.github/dependabot.yml:22` | npm ecosystem errors weekly `misconfigured_tooling` ("Set package-ecosystem: bun"); frontend deps frozen since 09-17. | `package-ecosystem: bun`. Then decide fate of `dependabot-lockfile.yml` (C6). |
| C6 | P1 = #541/#470 | `.github/workflows/dependabot-lockfile.yml` (last step `git push` with `GITHUB_TOKEN`) | Reconcile push triggers no workflows → PR head has no required checks → PR wedged (#527 since 2026-09-10). | **Decision order:** (a) after C5, if dependabot-bun updates `bun.lock` natively, delete `dependabot-lockfile.yml` → #541/#470 moot. (b) else: add `workflow_dispatch:` to `test.yml:3-6`; `permissions: actions: write` in lockfile workflow; after push `gh workflow run test.yml --ref "${{ github.event.pull_request.head.ref }}"` (GH_TOKEN=GITHUB_TOKEN — documented exception, does trigger). Replace "KNOWN LIMITATION" comment. |
| C7 | P1 sec | `.github/workflows/release.yml:22, 64-80` | `workflow_dispatch` accepts any ref; no `refs/heads/main` check before irreversible `gem push`. | `if: github.ref == 'refs/heads/main'` on preflight + assert in `release:check`; ideally protected `release` environment (HITL). |
| C8 | P2 | `.github/workflows/ecosystem.yml:40-52` | Filter misses `bin/**` (`bin/test-ecosystem`) and `ecosystem/**` (shim). | Add. |
| C9 | P2 | `Dockerfile:10` (`oven/bun:1.4.2-slim`) vs `test.yml:151,403`, `release.yml:120`, `dependabot-lockfile.yml:94`, `mise.toml:14` (1.4.0) | Bun drift; stale line refs in `dependabot.yml:43-46` comment. | Single version everywhere; drop line refs from comment (name the files only). |
| C10 | P2 | `test.yml:98-101`, `bin/check:13` | Comments say "4 workers"; since #536 default = half cores cap 4. | Fix comments. |
| C11 | P2 | self-hosted `wurk-ci` host runs ≥2 runners per machine (`/opt/actions-runner-1`, `-2`) | Each job sees full core count → oversubscribes (what #536 tried to avoid). | Set `NCPU` per runner env (infra side, [`10`](10-infrastructure.md)) or in workflow from runner label. |
| C12 | P2 | CLAUDE.md pillar 3 vs `bench.yml:29` | "blocks merge" claim false — bench not required. | Either require `bench vs base` (HITL) or reword CLAUDE.md. Recommend reword + keep bot comment, given runner variance (infra#1259). |

## Steps
1. C1+C3+C8 paths-filter PR (tiny, unblocks honest gating).
2. C4 (#469) per-step conversion.
3. C5 dependabot→bun; observe one weekly run (or trigger via Insights→Dependabot "Check for updates").
4. C6 per decision order; prove with `@dependabot recreate` on #527 → three required contexts appear on new head. Close #470 as dup of #541.
5. C7 release main guard.
6. C9/C10/C12 drift cleanup.

## Tests
- `actionlint` job (`test.yml`) green.
- Throwaway docs-only PR: `test + coverage`, `lint (rubocop)`, `parity (oracle)` report SUCCESS (ran, not SKIPPED) — and docs tests actually executed (check log).
- Throwaway PR touching only `.rubocop.yml` → lint runs.
- `release.yml` dispatched from non-main ref → fails at preflight before build.

## Done when
- #469, #541, #470 closed with evidence links.
- #527 either merged (vitest 5 compat fixed) or closed with reason.
- Dependabot bun job green 2 weeks running.
