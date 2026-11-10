# 19 — Infra repo: tesote/infrastructure

> Part of [`overview.md`](overview.md). Depends on: none. Edited from `~/workspace/tesote/infrastructure`, own PRs. Treasury manifests are read-only for this plan.

## Files to change
| ID | Where | Change |
|---|---|---|
| X1 | `stacks/tesote-com/k8s/base/deployment-sidekiq.yaml:66-71`, gringotts `deployment-sidekiq.yaml:69-82` | `ps \| grep` probes → `exec: bundle exec wurk health` (pattern: sales, commit `d4b98f6e`; test `stacks/sales/__tests__/worker-liveness.test.ts`). |
| X2 | `platform/observability/config/alerts.yml:1392-1393` ("none does today") | Scrape each worker's `/metrics`; import rules from Wurk `examples/kubernetes/prometheus-rule.yaml`: queue latency, `wurk_swarm_children_fresh < expected`, unconsumed queue ([`03`](03-boot-guards-preflight.md) G5), restarts ([`11`](11-observability-ops.md) O1). |
| X3 | per-stack configmaps (`WURK_DISABLED=1` repeated; "concurrency comes from wurk.yml" comments); `rails/bin/deploy/{start,wurk,rails}` duplicated in 3 app repos with `SIDEKIQ_*` synonyms | Leave until Wurk ships G3 role line; then trim to one documented env set. |
| X4 | grace vs `:timeout` (tesote.com 50/60) | Margin per Wurk `docs/deployment.md` sizing table. |

## Done when
- No `ps | grep` worker probe left: `grep -rn "grep.*wurk\|grep.*sidekiq" stacks/*/k8s` empty outside treasury.
- One Wurk alert fires in staging on a forced child crash loop.
