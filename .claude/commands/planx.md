---
description: Write a concise, self-contained execution plan to docs/plans/<YYYY>/<MM>/<DD>/<1NN>-<slug>/ for another AI to implement
argument-hint: [what you want done]
allowed-tools: Write, Read, Glob, Grep, Task, Bash
---

# /planx

Produce a concise plan another AI can execute with zero extra context. Plan only — no implementation, no code execution, no edits outside the plan dir.

## Goal
$ARGUMENTS

## Steps

1. **Resolve path.** Run `date +%Y`, `date +%m`, `date +%d`. Dir = `docs/plans/<YYYY>/<MM>/<DD>/`. `Glob docs/plans/<YYYY>/<MM>/<DD>/1*` → next number = highest existing `1NN-*` + 1, else `101`. Slug = kebab-case title, max 5 words. Final plan dir: `docs/plans/<YYYY>/<MM>/<DD>/<1NN>-<slug>/`.

2. **Explore.** `Task` (subagent_type=Explore, thoroughness="very thorough"): existing patterns + files to touch (`file:line`), the right workspace(s) under `apps/*` / `packages/*`, tests (unit vs integration), shared contracts in `@developerz/domain`, SQL in `@developerz/db`, policy schema in `@developerz/policy`, audit hooks in `@developerz/audit`, gotchas. Prefer `codegraph_*` for structural lookups. Skip only for trivial asks.

3. **Write the plan as multiple files** in the plan dir — never one big `plan.md`. Always produce an `overview.md` index plus one `<NN>-<aspect>.md` per separable area (e.g. `01-data-model.md`, `02-policy-schema.md`, `03-tool.md`, `04-api-routes.md`, `05-dashboard.md`, `06-tests.md`). Split by area of work so each file is independently executable and stays short. Match the existing house style in `docs/idea/` — terse fragments, `file:line` refs, tables.

   **`overview.md`** — the map. Sections:

```markdown
# <Title>

## Goal
1-2 sentences: what + why.

## Context
- Stack facts the executor needs (Bun + TS, Hono HTTP, Vercel AI SDK BYOK agent loop in `@developerz/agent`, Drizzle→Postgres 18, BullMQ on Dragonfly, SolidJS dashboard / SolidStart marketing — only what's relevant).
- Reference patterns: `packages/<pkg>/src/<area>/<thing>.ts:12` — follow this for Z.

## Plan files (execute in order)
1. [`01-<aspect>.md`](01-<aspect>.md) — one line: what it covers.
2. [`02-<aspect>.md`](02-<aspect>.md) — ...

## Done when
- Verifiable acceptance criteria spanning the whole feature.

## Risks / open questions
- Anything the executor must decide or watch.
```

   **Each `<NN>-<aspect>.md`** — one slice of work. Sections:

```markdown
# <NN> — <Aspect>

> Part of [`overview.md`](overview.md). Depends on: <NN-prior or "none">.

## Files to change
- `path:line` — what changes, why.

## Steps
1. Ordered, concrete actions. Reference `Class#method` / `file:line`, don't restate.

## Tests
- What to add/run. Tests written with the code. Command: `bun run test` (not bare `bun test`), `bun typecheck`, `bun lint`.

## Done when
- Verifiable acceptance criteria for this slice.
```

4. **Write a `status.yml`** in the plan dir (alongside `overview.md`) — the live tracker for this plan. New plans start `not_started` / `0%`. Get `created_by` + `owner` from `git config user.name` (the person running /planx). Leave `worked_by` empty — the executor sets it to their own `git config user.name` when they pick the plan up, so a plan written by one person can be worked by another. Shape:

```yaml
plan: <1NN>-<slug>
title: <human title from overview.md>
status: not_started        # not_started | in_progress | blocked | complete | superseded
created_by: <git config user.name>   # who authored the plan
worked_by: ""              # who is executing it; empty = unclaimed; executor fills with their git user.name
owner: <git config user.name>
percent: 0                 # 0–100, overall completion
current_focus: ""          # where it's at right now / next slice to pick up
slices:                    # one row per <NN>-<aspect>.md slice
  - file: 01-<aspect>.md
    status: not_started      # not_started | in_progress | complete
    percent: 0
evidence: []               # commits/PRs proving progress, e.g. ["#324", "abc1234"]
notes: ""
last_updated: <YYYY-MM-DD>
```

   Keep `status.yml` machine-readable (valid YAML, the enums above). It's the one file in the plan dir that IS a tracker — the `.md` slices stay reference maps (no checkboxes there).

## Rules
- Compact English. Fragments over sentences. `file:line` and `Class#method` symbol refs over prose. Tables for structured data.
- Reference-only: point at code, don't paste it or re-explain it ("follow `x.ts` but ...").
- No checkboxes (`[ ]`). Plain bullets. The plan is a reference map, not a tracker.
- Multiple files always: `overview.md` + `<NN>-<aspect>.md` slices. Never a single `plan.md`.
- Self-contained: executor reads only `overview.md`, the slice it's on, and the files those cite.
- Respect `CLAUDE.md` + `docs/idea/principles.md`: thin orchestrator (coding happens in the user's agent, not ours), BYOK only (never resell tokens), audit-first (if it isn't logged, it didn't happen), bot always discloses, no bot-on-bot loops, auto-merge default-on (only through machine gates: CI green + review + branch protections). No hardcoded state machines for policy — policy = prompt + tools. No abstractions before consumers; default to deletion.
- Stack rules: TS strict, no `any`, no `as` without a why-comment. Biome (no ESLint/Prettier). Zod at every boundary (webhook, env, yml, API request). Drizzle for SQL — all of it in `@developerz/db`. Path alias `@developerz/<pkg>`. `apps/*` import packages, never each other; packages never import apps. `domain` imports nothing internal.
- Cross-app or cross-repo work (`../infrastructure`, `sebyx07/infrastructure/stacks/`) → one `<NN>-<aspect>.md` per repo/app; note `../infrastructure` is edited from its own repo, not here.

## Output
```
✓ docs/plans/<YYYY>/<MM>/<DD>/<1NN>-<slug>/overview.md
  + 01-<aspect>.md, 02-<aspect>.md, … (one per area)
  + status.yml (tracker — status/owner/percent/current_focus)
Next: run an executor on overview.md.
```
