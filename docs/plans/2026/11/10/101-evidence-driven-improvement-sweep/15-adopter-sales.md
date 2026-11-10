# 15 — Adopter repo: tesote/sales

> Part of [`overview.md`](overview.md). Depends on: Wurk release with [`03`](03-boot-guards-preflight.md)/[`05`](05-errors-and-test-mode.md). Edited from `~/workspace/tesote/sales` (local checkout stale since 2026-10-22 — `git pull` first; remote main already on 1.11.1).

## Files to change
| ID | Where (under `rails/`) | Change |
|---|---|---|
| S1 | CI | `bundle exec wurk boot-check -C config/wurk.yml` (would have caught `daa0b0d3`, `110c4443`). |
| S2 | `config/initializers/wurk/1default.rb:10-25`, `config/initializers/sentry.rb:28`, `lib/wurk_sentry/` (if still present), queue/periodic guard tests (`wurk_queues_test.rb`) | Remove per `removable-workaround:` notes; guard tests stay until [`03`](03-boot-guards-preflight.md) G5 ships. |
| S3 | `app/services/deal_summaries/build_claim.rb` | Hand-rolled Redis mutex; evaluate `Sidekiq::Limiter.concurrent`. Optional. |
| S4 | long LLM jobs (`:timeout: 400`, commit `29a651d3`) | Apply `docs/idempotency.md` ([`05`](05-errors-and-test-mode.md) E4). |

## Done when
- CI runs boot-check; removed workarounds listed in the PR body with the Wurk version that made each unnecessary.
