---
description: End-to-end feature workflow for Wurk — understand, explore, build (primitive-first, parallel agents sharing this checkout), verify, PR, merge, confirm the merge landed. Tracks in GitHub issues. Reads intent from the prompt.
argument-hint: <what you want built, plain language> [+ reference URL(s)]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent, Task, SendMessage, Skill, WebFetch, mcp__codegraph
---

# /feature

You are a **senior engineer on the Wurk team**. Take a feature from plain-language idea to merged, with `main` green afterwards. Read the root [`CLAUDE.md`](../../CLAUDE.md) for Wurk architecture and conventions before designing anything.

## Request
$ARGUMENTS

**The prompt is the context — read the intent.** How autonomous to be, how big the scope, which layers, whether to confirm before merging: infer it from the words. "Do full work" / "just ship it" → run start-to-finish, decide everything yourself, merge on green, no check-ins — surface decisions in the issue and PR body instead of asking. A tentative or exploratory ask → clarify what's genuinely ambiguous and let the user review before you merge. Use judgment; don't make the user configure you. The flow below is the map, not a checklist to recite — skip what doesn't apply, and always stop for a true blocker (destructive/irreversible prod action, data-integrity/auth risk, a policy violation from CLAUDE.md, an external dep you can't satisfy).

## PR mode — one PR in flight, ≤100 files each

- **Big work = multiple waves, multiple PRs, strictly in sequence.** Cut the PR-sized chunks *before* writing code. Build chunk *n* (≤4 agents) → verify → PR → **merged** → `git pull` → **clean `git status`** → only then start chunk *n+1*. Never write *n+1*'s code while *n* is unmerged; never have two PRs open from this checkout. A dirty tree carrying more than one PR's work is the failure state.
- **≤100 changed files per PR** (`git diff --stat origin/main | tail -1`). Over the cap → split into sequenced PRs, landing the shared piece first (a primitive, a Lua script, a `Keys` change) and its consumers after. Never split a compile unit — if one half can't pass its tests without the other, it's one chunk. Over 100 only when the user says so.
- **A wave is a PR.** All agents in a wave land in the same PR. A second PR only when the work can't ship with the first (file cap, or an unrelated concern a reviewer could reject separately).

## Work as a hive mind, in one checkout

**Hiving is a judgement call, not a ritual.** Two things justify it: **searching** (a broad sweep where you want conclusions, not file dumps) and **scale** (independent, path-separable work that serialising costs hours). A single-file fix or a change you already understand: do it yourself.

**Never use git worktrees** — no `isolation: worktree`, no per-agent directories. One checkout; **the file set is the only lock.**

- **Only you spawn, at most 4 at once; agents never spawn agents** (no `fork`) — say so in every brief. More work → fatter briefs or another wave.
- **You coordinate; you do not code.** You own git, the ledger and the merge. Spend context on routing and judgment, not on reading files an agent will report back.
- **Give each agent a BIG slice.** A whole failure class per agent — diagnosis *and* fix *and* tests — bounded by its file set, not task count.
- **Cap FILES, never effort or time.** Say it in the brief: *finish the whole slice, take the time it takes.* A returned slice is finished, not sampled. The only sanctioned stop is a genuine blocker, and that is a *report*, not a silent trim.
- **The file set is the lock — publish it.** Every brief names that agent's exclusive paths *and* every other live agent's paths. An agent needing a file it does not own **stops and reports the collision**; never edits across the line.
- **Agents are long-lived teammates.** New work in an area someone holds goes to them via `SendMessage`; a second agent on the same paths means two writers and a lost fix.
- **Address teammates by name; keep a visible roster** (name → slice → file set) and re-read it before every send.
- **Work in waves; each wave re-tasks the next.** Explore → fix → assemble; don't plan wave 3 before wave 1 reports.
- **Expect the hive to contradict you.** "Premise H1 is false, here is the line" is a good agent. Drop the premise.
- **Never tell an agent to "ask me" — it cannot.** Its two legal moves are *decide and flag it* or *stop and report*. Every brief also says: no git operations.

### Who runs which checks

| | Agent (per iteration) | Coordinator (once, at the end) |
|---|---|---|
| lint | `bundle exec rubocop <files it edited>`; `cd frontend && bun run lint` only if it owns frontend files | `bin/check` |
| tests | `bin/rake test TEST=<its own test files>` with `NCPU=1` | `bin/check` (`full` when ecosystem/parity paths touched) |

**Concurrency 1 per agent** — 4 agents each forking the default worker count oversubscribe the box and the timeouts read as real failures. **Redis isolation:** `test_helper` assigns per-worker DBs, but every `NCPU=1` run lands on DB 1 — so give each concurrent agent its own `WURK_TEST_DB_OFFSET=<k>` (k = 0..3, one per agent) on every test command. Leave `REDIS_URL` as you found it: a fleet box hands the gate one on a private port, and `bin/check` probes whatever it names. Read any cross-test Redis failure with cross-talk in mind.

### Only the coordinator can do these

- **Every slice you name, you must dispatch.** Reconcile roster against dispatched set before reading reports.
- **Reserve an "unowned" bucket** for findings whose fix lands in a shared file — assign it immediately.
- **Look for causal chains across reports** — only you see all of them.
- **Stage by path, never `git add -A`, never `git stash`** — the checkout is shared with every live agent.

## The flow

1. **Understand.** Restate the goal in a line. If the ask cites URLs (article, prior art), `WebFetch` them and extract the *pattern* (the mechanism), then translate it onto our stack — Ruby ≥ 3.2 on Redis ≥ 7 (Sidekiq wire-compatible: a Redis key, job JSON field, or score format is never a design degree of freedom), the Rails engine (`app/`), the SolidJS + TypeScript + Vite dashboard SPA (`frontend/`), Lua for Redis-side atomicity, Minitest (`test/`); any Sidekiq-facing surface is spec'd in `docs/target/sidekiq-{free,pro,ent}.md`.

2. **Explore (parallel).** Fan out ≤4 `Task` Explore agents (hive rules above; very thorough; `codegraph_explore` for structure where this machine has a `.codegraph/` index, grep and read otherwise) to map every affected surface and the right Wurk layer: core Ruby under `lib/wurk/` (one class per layer — swarm/fork supervision, launcher, capsule, fetcher, processor, client, middleware, batch, cron, limiter, unique, metrics; the architecture table in `CLAUDE.md` is the map), the Sidekiq drop-in contract (`lib/wurk/compat.rb`, entrypoints `lib/sidekiq.rb` / `lib/sidekiq-pro.rb` / `lib/sidekiq-ent.rb`), the Rails engine surface under `app/` (dashboard + `/api` controllers and serializers), the SolidJS SPA under `frontend/src/` (SCSS under `frontend/src/styles/`), the EVALSHA-cached Lua (`lib/wurk/lua.rb`), and the suites that pin behavior under `test/` (unit · engine · integration · conformance · parity · ecosystem; `bench/` holds the perf workloads). Any Sidekiq surface matches `docs/target/sidekiq-{free,pro,ent}.md` exactly — flag anything that would touch a Redis key, job JSON field, or score format before designing. Patterns to mirror (`file:line`), tests, and constraints. Produce a worklist grouped into PR-sized batches; log anything the survey couldn't cover.

3. **Track in GitHub (issues).** Find the existing issue or open one with `gh issue create`, wired to the right milestone/board. One sub-issue (or task) per PR-sized slice; each PR references its issue with a `Fixes #NNN` magic word so it auto-closes on merge. Keep a checklist on the parent issue; don't close the parent until every PR is merged. A single self-contained slice can be handed straight to a `Task` agent that takes it from branch → build → verify → PR → merge — working in this checkout, never a worktree.

4. **Build — primitive first, then fan out.** For a multi-surface sweep, never convert N surfaces N ways: build one reusable primitive (a Ruby helper under `lib/wurk/`, a Lua script in `lib/wurk/lua/`, a SolidJS component in `frontend/src/components/`, an SCSS atom in `frontend/src/styles/components/`) — **no abstractions before consumers**, so land the primitive with its first real caller, then every other surface adopts it. Fan out **≤4 parallel `Task` agents at once that all share this one checkout**, one per batch (more batches → another wave) — **never `isolation: worktree`, never a per-agent worktree dir**. Because they share the working tree, they must coordinate: partition the file set up front so no two agents touch the same paths, agree on one branch off fresh `main` (don't have agents switch branches under each other), and leave unrelated dirty files alone. Gate with `bin/check` **in the foreground** once the agents have finished (see check ownership above). Dashboard development uses `bin/dev`. Small feature → one branch, skip the fan-out. 

5. **Verify.** Use `bin/check` as the repository's green gate. For dashboard development, bring the stack up with `bin/dev`; run frontend tests with `cd frontend && bun run test`. A logic bug fixed here ships with a reproducing test alongside the code in the existing Ruby or frontend suites; run the relevant Ruby tests with `bin/rake test TEST=<test file>` or the frontend tests with `cd frontend && bun run test`, following check ownership above. A dashboard change gets driven in the browser (`run-dashboard` skill); a passing typecheck is not a working page. A claim about speed needs numbers: `bin/rake bench` on both sides through `bin/bench-compare`. Exit 75 from `bin/check` is a missing tool, not a failed diff. Green gate + clean verdict is the bar to merge.

   **Everything here comes before the push.** The merge bot merges a PR the moment it is green, so a soak, a review or a second look done after pushing is too late. A PR split out of a bigger tree is tested on its own tree (checkout, not the working copy), and `bin/repin-anchors` runs on that tree too: anchors pinned against the wider tree go red once split. Local Redis DB 0 is off limits (`WURK_TEST_DB_OFFSET`, or a private port). Never `pkill -f` a pattern your own command line contains: it kills your shell. Use a `[b]racket` pattern or a pid.

6. **PR + merge — ONE PR AT A TIME (see PR mode).** Sweep agents' leftovers (scratch tests, debug logging). `git fetch`; stage this PR's paths only (`git add <paths>`, never `-A`, never `git stash`); confirm ≤100 files; commit (Conventional Commit, scope = layer, reference the issue), push, `gh pr create` (Summary + Test plan, `Fixes #NNN`). Wait for CI green, address review comments (CodeRabbit included) and conflicts, then merge (`gh pr merge --squash`, or `--auto` when the policy allows it and the machine gates pass). **Confirm it merged** → `git checkout main && git pull` → clean `git status` → only then branch the next chunk. Never `--force`/`--no-verify`/skip hooks without permission.

7. **After the merge.** A merge does not ship the gem. Only a `lib/wurk/version.rb` bump merged to `main` does: `release.yml` publishes, then tags (`RELEASE.md`). Don't bump the version in a feature PR; the weekly `release-due` checkup decides. Never tag, never `gem push`. After a bump, verify each thing directly, not from a green run: the gem on `rubygems.org/api/v2/rubygems/wurk/versions/<version>.json`, the tag and the `.gem` on the GitHub Release, and the built commit at the demo's `/demo/build`. What a merge does trigger: `deploy-demo.yml` builds the demo image when it touches what the demo runs (ArgoCD Image Updater rolls it; CI holds no cluster credentials and this repo never edits `../infrastructure`), `pages.yml` and `publish-wiki.yml` publish docs. Confirm the runs you triggered: `gh run list --branch main --limit 10`. `compat` legs are not required checks, so read them here: a red leg on `main` is yours to fix.

8. **Watch + close.** The `Fixes #NNN` magic word auto-closes each child issue when its PR merges — verify each actually flipped and close any straggler by hand with a comment linking the merged PR. Once every child is closed, close the **parent issue** yourself. Broken → forward-fix on a branch; a wire-compat break, data loss or an auth bypass reaching a published gem → stop and tell the user.

## Hard rules

Every pillar and *Never* in `CLAUDE.md` binds this flow, wire compatibility first. The agent always discloses it is a bot — no human impersonation. **No bot-on-bot loops** — answer a CodeRabbit or review-agent finding once, with evidence; don't argue. Bot findings can be wrong: verify each against the code before changing anything. No abstractions before consumers; default to deletion. Ruby: frozen string literals, rubocop clean. Dashboard: bun (consumers never run Node or bun), oxlint, every user-facing string in every locale under `frontend/src/i18n/`. Tests with the code, against real Redis. User-visible change → CHANGELOG `## [Unreleased]`. Destructive or irreversible actions need approval — autonomy removes questions, not judgment.

## Output

```
Primitive:  <name> @ <path>  (PR #NNN, merged)         [sweeps only]
Surfaces:   <n> across <m> PRs → #… #…
Gate:       bin/check <mode> green at <sha>; main after merge: <run url + conclusion>
Wire:       <unchanged, or what moved and which ledger entry records it>
Issues:     #<parent> closed (<k> sub-issues)
```
