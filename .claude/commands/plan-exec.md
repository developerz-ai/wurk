---
description: Execute a /planx plan dir wave by wave — status.yml as the ledger, one PR per wave, ≤4 agents with disjoint file sets, human rows never decided silently.
argument-hint: <plan dir, e.g. docs/plans/2026/11/10/101-…> [extra scope]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent, Task, SendMessage, Skill
---

# /plan-exec

You are the **coordinator** executing a plan written by `/planx`. `/feature`'s hive rules (`.claude/commands/feature.md`) bind you: one checkout, no worktrees, ≤4 agents at once, only you spawn, only you touch git, one PR in flight. This file adds what a multi-wave plan needs on top.

## Request
$ARGUMENTS

## 1. Read the plan as a ledger
- `overview.md` (waves, risks, done-when), `status.yml` (what is already done), the human-decisions file.
- Two plans for the same work (an "Overlap" note)? Pick one as plan of record, mark the other `superseded`, fold its unique rows in, and say so in both `status.yml` files.
- Re-verify before trusting: plan line refs drift, "inferred" rows need a reproducing test first, and a row may already be done (agents find stale premises — accept "premise false, here is the line").

## 2. Run a wave
- One wave = one branch off fresh `main` = one PR. Create the branch yourself before any agent starts; agents never switch it.
- Brief each agent with: its plan rows by ID, its **exclusive file set**, every other live agent's file set, "no git, no spawning, no worktrees", `eval "$(bin/redis env agent-<k>)"` for its own Redis, "finish the slice; a blocker is a report", and a **"DX friction"** section in its report. Agents never edit `CHANGELOG.md`, `docs/changelog/`, `CLAUDE.md` files or `.claude/`: they report proposed text and you apply it.
- Other repos (adopters, infra) run in parallel from their own checkouts: each agent follows that repo's own CLAUDE.md and merge rules (some forbid `gh pr merge`; a bot merges).
- Read-only surveys (perf ideas, inventories) can run while a wave builds: they feed later waves, never the current PR.

## 3. Before the PR
- An agent's change that contradicts an earlier recorded decision (a brief under `.dz/`, a CLAUDE.md rule, a dated `status.yml` decision) is reverted, not merged: the earlier human call wins until a human changes it.
- Apply the agents' patches for files they did not own, then: `bin/repin-anchors` on this tree, `bin/check` (`full` if ecosystem/parity paths changed), stage by path, ≤100 files.
- PR body claims only what the diff does; evidence you lack is listed as missing.

## 4. After the merge
- Confirm merged → `git checkout main && git pull` → clean tree. Read the `main` runs you triggered, compat legs included.
- Update `status.yml`: slice `status`/`percent`, an `evidence:` line per merged PR or verified deploy, `current_focus` for the next wave. Commit it with the next wave's PR, never alone.
- Deploys: verify in the target (pod Ready, probe passing, `/demo/build`), not from a green run. Releases follow `RELEASE.md`; never tag, never `gem push`.

## Human rows
Breaking defaults, security calls, secrets only the owner holds, paid or public claims: never decide them. Record a recommendation and the blocker in `status.yml`. When the owner decides in-session, record it as a dated decision (`by: <owner>`) next to the guard or doc it changes.

## Output
Per wave: PR link + merge state, rows done, rows deferred with reason, deploy/release evidence, open human rows.
