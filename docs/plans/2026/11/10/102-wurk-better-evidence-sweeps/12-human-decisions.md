# 12 — Human decisions + adopter follow-ups

> Part of [`overview.md`](overview.md). No agent decides these (CLAUDE.md: "Merge a breaking change without a human decision" = Never). Each row: the question, the recommendation, what it unblocks. Record the dated answer in `status.yml` `notes`.

## Decisions

| ID | Question | Recommendation | Unblocks |
|---|---|---|---|
| H1 | Make the railtie's embedded swarm opt-in everywhere (`WURK_EMBED=1` / `config.wurk.embed_in_web`), incl. single-mode Puma? Breaking for apps relying on auto-embed. | Yes, next major (2.0). All 5 adopters already disable it; it caused double-runs, a fork-bomb and wiped dev queues. | B1 breaking half |
| H2 | Publish the `sidekiq` shim somewhere other than a git source (separate small repo, or a private gem source under the name `sidekiq`)? Trademark + source-block implications. | Not now. Tag-pinned git recipe (B6) + `exe/sidekiq` in wurk (B5) + runtime hybrid detection (B4) cover it. | B6 scope |
| H3 | Default `WURK_COUNT` for `wurkswarm`: keep one fork per core, or 1 + boot WARN when unset? Ent default = per `docs/target/sidekiq-ent.md` — check before deciding; diverging needs a ledger entry. | Keep parity default; add the boot sizing line (B8). | B8 |
| H4 | `mgr.authoritative!` (periodic registry prunes loops the code no longer registers) as default? | Decide after B9 ships the WARN; default flip is breaking for multi-app Redis sharing. | B9 |
| H5 | Default `redis_idle_timeout` (~300s) instead of nil? | Yes if #530/#537 history has no counter-evidence — read those issues first. | M11 |
| H6 | Rack-mode dashboard host for non-Rails apps (`run Sidekiq::Web` in Sinatra/Roda/Hanami)? Large. | Defer; no adopter or pool app needs it. | W16 |
| H7 | **Obtain a scrubbed Redis dump from a real Sidekiq Pro 7.3 + Ent deployment** (treasury staging is the candidate): must include a SIGKILLed super_fetch process's private lists, unique locks, periodic loops, metrics history, batches if any. Read-only export; scrub PII. (Carried over from the 2026-10-04 audit as U8 — still open.) | Do it; it is the only way to settle E2 without reading licensed source. | E2, old R2/R3 |
| H8 | Offer `config.legacy_float_timestamps` (write seconds-float timestamps like Sidekiq 7) for 7.x migrants and symmetric rollback? Changes what wurk writes — permitted only as restoring a Sidekiq format. | Lean no: source scan + cop (E1 a/b) fix the reader side; a write-format switch doubles the wire surface to test. Revisit if treasury cutover planning asks for 7.x rollback. | E1(c) |
| H9 | Additive heartbeat `info` field for PSS (precedent: `host_facts`)? | Only if an operator asks; O6 exports it via `/metrics` without touching Redis. | O6 |
| H10 | Publish the Python client to PyPI (trusted publishing)? | After OpenAPI contract test (W13). | C8 |
| H11 | Opt-in key prefix for per-app Redis ACL isolation (infra note: "no prefix to grant ⇒ only workable ACL is `~*`")? **Not wire-compatible** — a prefixed app is no longer drop-in with Sidekiq tools on the same Redis. | No. Violates pillar 1; recommend one Redis (or logical DB + ACL `select`) per app in `docs/deployment.md`. | infra ask closed with a doc |

## Adopter follow-ups (other repos — each edited from its own checkout, own PR; treasury excluded)

| App | Action | After |
|---|---|---|
| `tesote/tesote.com` | Add `Sidekiq::Enterprise.unique!` (or remove `unique_for` from `BroadcastDeliverJob`) — dedup has never worked. Tell the owner now; do not wait for R3. Switch probe from `ps \| grep` to `wurk health`. | immediately / B11 |
| `tesote/gringotts-wizarding-bank` | Probe → `wurk health`; `:timeout` 25 vs grace 900 review. | — |
| `developerz-ai/legaldiligencemedellin.com` | Add a worker liveness probe (`wurk health`); set termination grace > `:timeout`; refresh stale `.claude/skills/wurk-runner/SKILL.md`. | — |
| `hiscore/hiscore.ro` | Replace hand-rolled capistrano/systemd with shipped examples; `RestartSec`/`StartLimitBurst`; drop `config.topology` (ignored under `exe/wurk`) or move to `wurkswarm`. | B12 |
| all five | Bump to the release carrying 01 + 02; delete workarounds listed as stale in `docs/upgrading.md` (B17); add `wurk boot-check` to CI; expose `/metrics`. | release |
| `tesote/sales` local checkout | Stale (last fetch 2026-10-22) — `git pull` before any work there. | — |

## Done when
- Every H-row has a dated decision in `status.yml`.
- tesote.com owner notified of the `unique_for` no-op (link to the message/issue in `status.yml` `evidence`).
