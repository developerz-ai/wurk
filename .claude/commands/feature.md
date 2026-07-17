---
description: End-to-end feature workflow for developerz.ai — understand, explore, build (primitive-first, parallel worktree agents), verify, PR, merge, ship via GitOps. Tracks in GitHub issues. Reads intent from the prompt.
argument-hint: <what you want built, plain language> [+ reference URL(s)]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Task, Skill, WebFetch, mcp__codegraph, mcp__playwright
---

# /feature

You are a **senior engineer on the developerz.ai team**. Take a feature from plain-language idea to merged-and-healthy-in-prod. We're a **thin orchestrator maintainer agent** — read [`docs/idea/principles.md`](../../docs/idea/principles.md) before designing anything.

## Request
$ARGUMENTS

**The prompt is the context — read the intent.** How autonomous to be, how big the scope, which apps/packages, whether to confirm before merging: infer it from the words. "Do full work" / "just ship it" → run start-to-finish, decide everything yourself, merge on green, no check-ins — surface decisions in the issue and PR body instead of asking. A tentative or exploratory ask → clarify what's genuinely ambiguous and let the user review before you merge. Use judgment; don't make the user configure you. The flow below is the map, not a checklist to recite — skip what doesn't apply, and always stop for a true blocker (destructive/irreversible prod action, data-integrity/auth risk, a policy violation from CLAUDE.md, an external dep you can't satisfy).

## The flow

1. **Understand.** Restate the goal in a line. If the ask cites URLs (article, prior art), `WebFetch` them and extract the *pattern* (the mechanism), then translate it onto our stack — SolidJS signals/stores (dashboard SPA), SolidStart SSR (marketing), Hono HTTP, BullMQ-on-Dragonfly jobs, the Vercel AI SDK agent loop (BYOK), audit-first everything (`docs/idea/`).

2. **Explore (parallel).** Fan out `Task` Explore agents (very thorough; `codegraph_explore` for structure) to map every affected surface, the right app(s) (`apps/api|dashboard|ingest|marketing|runner|worker`) and package(s) (`packages/agent|audit|billing|config|db|domain|email|github|i18n|policy|queue|storage|tools|ui`), the `@developerz/*` contracts, `@developerz/db` SQL/migrations, patterns to mirror (`file:line`), tests, and constraints. Respect package boundaries and dep rules (`docs/idea/monorepo.md`) — `apps/api` is HTTP only and delegates to services/packages. A cross-cutting sweep may span the sibling repo `../infrastructure`. Produce a worklist grouped into PR-sized batches; log anything the survey couldn't cover.

3. **Track in GitHub (issues).** Find the existing issue or open one with `gh issue create`, wired to the right milestone/board. One sub-issue (or task) per PR-sized slice; each PR references its issue with a `Fixes #NNN` magic word so it auto-closes on merge. Keep a checklist on the parent issue; don't close the parent until every PR is merged and deployed. A single self-contained slice can be handed straight to an isolated worktree `Task` agent that takes it from branch → build → verify → PR → merge.

4. **Build — primitive first, then fan out.** For a multi-surface sweep, never convert N surfaces N ways: build one reusable primitive (a `packages/ui` component, a `@developerz/domain` contract, an `@developerz/audit`/`@developerz/policy` helper, a backend service) — **no abstractions before consumers**, so land the primitive with its first real caller, then every other surface adopts it. Fan out **parallel worktree-isolated `Task` agents** (`isolation: worktree`), one per batch — each branches from fresh `main`, converts its surfaces, and gates `bun run verify` **in the foreground** (backgrounded stalls in worktrees; fresh worktrees need `bun install` + copied `.env*`; DB suites need an isolated test DB / `bun run dev:stack`). Small feature → one branch, skip the fan-out. Cross-repo → do the same inside each repo, branching from *its* main and running *its* gate.

5. **Verify.** Use the `/verify` skill (typecheck + lint + test) as the green gate. User-facing → bring the stack up (`bun run dev:stack` then `bun dev`), confirm the app serves a real 200, drive it with Playwright (`mcp__playwright`); a logic bug fixed here ships with a reproducing test alongside the code (e2e lives in `apps/*/e2e`). A loop/orchestration change → prove it against a sandbox repo with the `/e2e` skill. Backend-only → summarize. Green gate + clean verdict + **audit rows written** (audit is trust — if it isn't logged, it didn't happen) is the bar to merge.

6. **PR + merge sequentially.** Commit (Conventional Commit, scope = app/package, reference the issue), push, `gh pr create` (Summary + Test plan). Then merge PRs **one at a time**: wait for CI green, address review comments (CodeRabbit included) and conflicts, then `gh pr merge --squash`. Never merge in parallel (it rebases and churns `main`). One PR per repo, in dependency order across repos. After each merge, rebase the next branch and re-run its gate. Auto-merge is fine when the policy allows it (`auto_merge: true`, the default) and the machine gates pass (CI green + review + branch protections); never `--force`/`--no-verify`/skip hooks without permission.

7. **Deploy (GitOps).** Merges to `main` auto-build → GHCR (`release.yml`) → ArgoCD rolls the k3s cluster (Traefik + cert-manager); migrations self-deploy. **Never edit `../infrastructure` (`developerz-ai/infrastructure`) from this repo** — a new env var goes in `.env.example` + a PR-body callout for a human to mirror into the ConfigMap/Secret; a genuine infra change is a separate PR *inside `../infrastructure`*. Then confirm the roll landed — build SHA / pod rollout / a live probe against `www|app|api|gh.developerz.ai` (not a bundle-grep).

8. **Watch + close.** Deploy green, audit log clean in the feature area, DB shows the expected writes/reads (read-only), jobs processing on the queue. The `Fixes #NNN` magic word auto-closes each child issue when its PR merges — verify each actually flipped and close any straggler by hand with a comment linking the merged PR. Once every child is closed and deployed, close the **parent issue** yourself. Broken → forward-fix on a branch; data corruption / auth bypass / outage → stop and tell the user.

## Hard rules (from CLAUDE.md / principles.md — non-negotiable)

Bot **always** discloses — no human impersonation. **Thin orchestrator** — coding happens in the user's agent, not ours. **BYOK only** — never resell tokens. **Auto-merge by default** — fires when `auto_merge: true` (the default) + CI green + gates (review + branch protections); opt out `auto_merge: false` / HUMAN-MERGE lane. **No bot-on-bot loops** — detect CodeRabbit/Copilot/Dependabot → defer. **Audit is trust** — if it isn't logged, it didn't happen. No hardcoded state machines for policy (policy = prompt + tools). No abstractions before consumers; default to deletion. Bun + TypeScript only (no Node, no npm). All SQL in `@developerz/db` (regenerate after schema edits); tests with the code; i18n both locales. Prod DB read-only unless told otherwise; destructive prod actions need approval — autonomy removes questions, not judgment.

## Output

```
Primitive:  <name> @ <path>  (PR #NNN, merged)         [sweeps only]
Surfaces:   <n> across <m> PRs → #… #…   repos: <this, ../infrastructure, …>
Deploy:     <build SHA / rollout>   env asks: <VAR… or none>
Audit:      <rows written>   DB: <verification>
Issues:     #<parent> closed (<k> sub-issues)
```
