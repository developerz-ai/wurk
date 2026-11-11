# 13 — Human decisions (HITL)

> Part of [`overview.md`](overview.md). Nothing here is done by an agent. Each row: the decision, the recommendation, what it unblocks. Record dated outcomes in `status.yml` `notes`. A breaking change never merges without one of these.

| ID | Decision | Recommendation | Unblocks |
|---|---|---|---|
| U1 | Require the Ruby 3.2 compat leg (ruleset `main-protection`; read live: `gh api repos/developerz-ai/wurk/rulesets`) | Require on `lib/**` | [`12`](12-proof-harness.md) T5 |
| U2 | `DEVELOPERZ_API_KEY` secret for the ecosystem watcher, or accept skip-with-notice | Add secret | [`01`](01-ci-green-doc-truth.md) C2 |
| U3 | Ship a `sidekiq` executable in the wurk gem | Yes — it is the drop-in contract; G2 guards the clash | [`04`](04-drop-in-surface.md) D1 |
| U4 | `unique_for:` used without `unique!`: WARN only, or auto-enable | WARN in 1.x (Ent requires `unique!`; auto-enable is a divergence) | [`03`](03-boot-guards-preflight.md) G1 |
| U5 | Default `WURK_COUNT` when unset under `wurkswarm` (today: per core; surprised sales + hiscore). Sidekiq Ent swarm default is the reference | Keep parity with Ent's default; log the effective count (G3) | [`11`](11-observability-ops.md) K3 |
| U6 | Embedded swarm opt-in everywhere (`WURK_EMBED=1`, Puma included) + `authoritative!` periodic default — both breaking | Next major only; 1.x gets the role log line (G3) | [`03`](03-boot-guards-preflight.md), [`11`](11-observability-ops.md) K4 |
| U7 | Per-queue "ACK on completion" option (narrows the SIGKILL re-run window; costs a round-trip per job on those queues) | Offer opt-in if treasury's payments queue needs it; bench first | [`04`](04-drop-in-surface.md) D8 |
| U8 | Opt-in Redis key prefix for per-app ACL isolation (`developerz-ai/infrastructure/.agent-setup/openclaw-profile/memory/dragonfly-per-app-sprawl.md:72-82`) — explicitly NOT wire-compatible with Sidekiq tooling | Decline unless the infra owner needs it; a logical DB / separate instance is the compatible answer | — |
| U9 | Same-origin guard: fall back to `Origin`/`Host` match when `Sec-Fetch-Site` is absent (plain-HTTP dashboards) | Security review first; default stays deny | [`09`](09-dashboard.md) W3 |
| U10 | Carry-over from the 2026-10-04 audit (`docs/plans/2026/10/04/101-squeaky-clean-audit/11-human-actions.md` U8): real Pro/Ent Redis dump from the customer | Still wanted; validates reaper key shapes + batch/limiter formats | [`12`](12-proof-harness.md) |
| U11 | Treasury cutover timing (read-only today) | After slices 02–05 + a 24h soak | — |
| U12 | Public production-volume line ("billions of jobs a month", recommended by production users) | **Decided 2026-11-10 by owner:** allowed, labelled user-reported; throughput figures still need [`12`](12-proof-harness.md) T1 numbers | README / site / llms.txt; `forbidden_claims_test.rb` |
