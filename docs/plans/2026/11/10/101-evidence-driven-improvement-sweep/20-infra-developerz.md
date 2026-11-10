# 20 — Infra repo: developerz-ai/infrastructure

> Part of [`overview.md`](overview.md). Depends on: none. Edited from `~/workspace/developerz-ai/infrastructure`, own PRs.

## Files to change
| ID | Where | Change |
|---|---|---|
| X1 | `stacks/apps/legaldiligencemedellin/manifests/deployment.yml:412-421` (note proposes `config.health_check`, unaware of `wurk health`) | Worker liveness `exec: bundle exec wurk health`; `terminationGracePeriodSeconds` > worker `:timeout`. |
| X2 | `.agent-setup/openclaw-profile/memory/dragonfly-per-app-sprawl.md:72-82` | Record the outcome of [`13`](13-human-decisions.md) U8 (key prefix declined/accepted) so the note stops being an open question. |
| X3 | Dragonfly job stores | Check each Wurk app's store stays below `maxmemory` (Wurk `docs/deployment.md`); add the alert. |

## Done when
- legald worker has a probe; forced crash loop restarts the pod.
