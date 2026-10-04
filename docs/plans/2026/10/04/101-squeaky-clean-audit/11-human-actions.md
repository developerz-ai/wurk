# 11 — Human-only actions (HITL)

> Part of [`overview.md`](overview.md). Things no agent can do: settings, accounts, decisions, external data. Each row says exactly what the human does and what it unblocks.

| ID | Action | Who | Unblocks |
|---|---|---|---|
| U1 | Add `spec docs` (and optionally `frontend (vitest)`, `actionlint`) to ruleset `main-protection` (id 20556704) required checks — *after* [`05`](05-ci-gates.md) C4 makes them always report. | repo admin | C2 — spec deletion un-mergeable |
| U2 | Create protected `release` environment (required reviewer or branch policy = `main`) and bind RubyGems trusted publishing to it. | repo admin | C7 hardening beyond the `if:` guard |
| U3 | Decide bench gate: require `bench vs base` **or** accept CLAUDE.md reword. Recommendation: reword (runner variance). | maintainer | C12 / H3 |
| U4 | Decide rubocop pinning (#471). Recommendation: pin. | maintainer | #471 → #477 |
| U5 | Re-triage #477 (last bot comment NEEDS-SPEC; body already revised) → mark ready. | maintainer | #477 |
| U6 | #530 owners post outcome (both arm records or failure records + reviewer verdict) or declare abandoned; close #530; release #537 for ordinary work. Stopping rule already elapsed (24h from #537 open 2026-09-19). | #530 owners | #537 (`:redis_idle_timeout`) |
| U7 | #441: create/verify AlternativeTo account; submit with issue-body fields (lead "background job system", no "faster"/AI-first, non-affiliation line, `docs/assets/wurk-logo.png`, ≥2 dashboard screenshots); pay $5 Priority Review; post URL on issue; close. | marketing/human | #441 |
| U8 | **Obtain a real Sidekiq Pro + Ent Redis dump from the customer** (staging): in-flight batches (nested), limiters (all types), unique locks, periodic loops, a SIGKILLed super_fetch process's private lists, metrics history. Scrub PII. | customer + account owner | R2, R3, E13, R4 validation |
| U9 | Agree support channel + response SLA + LTS/patch policy with the customer; decide whether to cut 1.0 / reconcile "pending v1.0.0 sign-off" wording. | owner | R20 |
| U10 | Infra: revoke the personal `read:packages` token behind `ghcr-pull-secret.yml`. | infra owner | X4, #800 |
| U11 | Infra: bench runner decision (`wurk-bench` vs Blacksmith exception + deregister ci-2-3); #1318 approval; #1285 decisions (GH App, orchestrator host). | infra owner | X7, #1259, #1285 |
| U12 | Coordinate demo-file edits with Din (owner of `demo/`): I1 producer gate, I7 Sentry. | owner | I1, I7, #502 app half |
| U13 | Pick one: the culprit that deletes `docs/target/` — if it's an agent config, fix it at source. | maintainer | H1 recurrence |

## Done when
- Every row has a dated decision or completion noted in `status.yml` `notes`.
