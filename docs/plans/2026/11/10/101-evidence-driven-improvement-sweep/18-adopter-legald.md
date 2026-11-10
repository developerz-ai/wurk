# 18 — Adopter repo: developerz-ai/legaldiligencemedellin.com

> Part of [`overview.md`](overview.md). Depends on: Wurk release. Edited from `~/workspace/developerz-ai/legaldiligencemedellin.com`.

## Files to change
| ID | Where (under `backend/`) | Change |
|---|---|---|
| S1 | worker Deployment — [`20`](20-infra-developerz.md) | No liveness probe, no grace period → add `wurk health` + grace > `:timeout`. |
| S2 | `config/initializers/sentry.rb:12-14` (reports every attempt) | Use `report_after_attempts:` ([`05`](05-errors-and-test-mode.md) E3). |
| S3 | `test/test_helper.rb:68-74,126` (`Sidekiq.redis` stub) | Remove after [`05`](05-errors-and-test-mode.md) E7. |
| S4 | `config/initializers/wurk.rb:104-118` (blocks `GET /profiles/:key` for read-only sessions) | Remove after [`09`](09-dashboard.md) W5. |
| S5 | `.claude/skills/wurk-runner/SKILL.md` | Stale vs `CLAUDE.md:333`; fix. |
| S6 | `app/jobs/article_generation_job.rb:53-58` | Idempotency per `docs/idempotency.md`. |
| S7 | Pool == concurrency (`RAILS_MAX_THREADS` 5 drives both) | Add headroom per [`11`](11-observability-ops.md) K3. |

## Done when
- Worker pod restarts when children crash-loop (probe test in infra repo).
