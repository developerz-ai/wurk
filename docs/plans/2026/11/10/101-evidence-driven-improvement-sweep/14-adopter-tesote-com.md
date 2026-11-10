# 14 — Adopter repo: tesote/tesote.com

> Part of [`overview.md`](overview.md). Depends on: none for S1 (do now); the rest after the Wurk release carrying [`03`](03-boot-guards-preflight.md)/[`05`](05-errors-and-test-mode.md). Edited from `~/workspace/tesote/tesote.com`, own PRs, own CI. Local checkout may lag remote: `git pull` first.

## Files to change
| ID | Where (under `rails/`) | Change |
|---|---|---|
| S1 | `app/jobs/broadcast_deliver_job.rb:11` (`unique_for: 5.minutes`); `config/initializers/wurk/` | **Live bug**: no `unique!` anywhere (`git log -S'unique!'` empty) → dedup never ran; `app/services/broadcast/deliver_recipient.rb:8-12` cites it as the idempotency guard. Add `Sidekiq::Enterprise.unique! unless Rails.env.test?` (hiscore pattern: `hiscore.ro/config/initializers/wurk.rb:16-22`). Test: second `perform_async` with same args returns nil. Check for duplicate broadcast sends in prod data before/after (owner's call how). |
| S2 | `Gemfile` (`~> 1.10`), `Gemfile.lock` | Bump to current Wurk. |
| S3 | infra probe — see [`19`](19-infra-tesote.md) | `ps \| grep` → `wurk health`. |
| S4 | `config/initializers/wurk/1default.rb:37-50` (5s `read_timeout`), `config/application.rb:45` (`require 'active_job/queue_adapters/wurk_adapter'`), `config/initializers/sentry.rb:15-44` (excluded list), `JOBS_ENABLED` periodic gate | Remove each only when the Wurk release notes list it under `removable-workaround:` ([`11`](11-observability-ops.md) K5) and `wurk boot-check` passes in CI without it. |
| S5 | CI | Add `bundle exec wurk boot-check -C config/wurk.yml` step. |
| S6 | `CLAUDE.md` "trap 4" (`Sidekiq::Web` 404) | Stale since 1.11; delete. |

## Tests
- App suite; `wurk boot-check`; `wurk verify` after deploy.

## Done when
- S1 merged + deployed; duplicate-enqueue test green.
