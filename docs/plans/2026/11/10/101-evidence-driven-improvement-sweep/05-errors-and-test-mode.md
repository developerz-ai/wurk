# 05 — Error reporting + test mode

> Part of [`overview.md`](overview.md). Depends on: none. Source: 5/5 adopters rebuilt error wiring; 3/5 patch test mode. 2 PRs (E1–E4 · E5–E8).

## Files to change
| ID | Kind | Where | Evidence | Change |
|---|---|---|---|---|
| E1 | BUG? | `lib/wurk/rails_reloader.rb:13-30` (`reloader.wrap(source: 'job.sidekiq')`); `lib/wurk/processor.rb:448` `build_instance` | sales `548fd9dc`: missing job class reported "1 per attempt, not terminal-only, via Rails.error"; Sentry SALES-APP-21 mechanism=`rails`, frame `processor.rb:448`. Treasury sets `register_error_subscriber = true` + `report_after_job_retries = true` → risk of one event per attempt × `retry: 10` on 41 jobs. Unknown whether stock Sidekiq 7.3/8.1 does the same. | First: oracle in `test/parity/` — which exceptions reach `Rails.error` subscribers per attempt under stock Sidekiq 8.1 (bench Gemfile has it) vs Wurk, incl. `JobRetry::Handled`/`Skip` and `build_instance` NameError. Then match upstream; if Wurk reports more, stop the extra reports. If upstream also reports per attempt: document, no code change. |
| E2 | feature | `lib/wurk/sentry.rb` (`Wurk::Sentry.install!`) | 3 apps hand-maintain `excluded_exceptions` for Wurk control-flow + `RedisClient` errors (sales `config/initializers/sentry.rb:28`, tesote.com `sentry.rb:15-44`, gringotts `sentry.rb:9-28`). | `Wurk::Sentry.excluded_exceptions` (frozen list of control-flow class names) + doc snippet `config.excluded_exceptions += Wurk::Sentry.excluded_exceptions`. No auto-install (owner vetoed gem-side reporting, #277). |
| E3 | docs | `docs/sentry.md`, `docs/migrate-from-sidekiq.md` | legald reports every attempt because terminal is ~21 days out (`backend/config/initializers/sentry.rb:12-14`); `report_after_attempts:` exists, nobody found it. Bugsnag (hiscore) undocumented. | Surface `report_after_attempts` in the guide's Sentry step; add Bugsnag/Honeybadger/AppSignal rows (what works out of the box via `error_handlers`). |
| E4 | feature | `lib/wurk/processor.rb` / `lib/wurk/manager.rb:145-165` `hard_shutdown`; job context | Deploy-time requeue re-ran long jobs: sales `29a651d3` (LLM calls billed twice, `:timeout` 25→400), legald duplicate article (`app/jobs/article_generation_job.rb:53-58`). | Log requeued jids + class at hard shutdown (one line each, capped). New `docs/idempotency.md` (at-least-once windows: hard shutdown, SIGKILL ACK window, scheduled promote lease). Exposing "was interrupted" to the job needs a JSON field → **not allowed** unless upstream has one; check `docs/target/` for an existing interrupt marker (IterableJob has cursor state) before proposing. |
| E5 | DX | `lib/wurk/testing.rb` (+ `lib/wurk/unique/` client middleware) | hiscore skips `unique!` in test because the client middleware needs Redis (`config/initializers/wurk.rb:16-22`). | Compare with Ent: under `Sidekiq::Testing.fake!`/`inline!` unique is bypassed upstream (check `docs/target/sidekiq-ent.md` unique section). Match it; oracle test. |
| E6 | DX | `lib/wurk/testing.rb` | hiscore monkeypatches `perform_async`/`perform_in`/AJ enqueue (`spec/support/wurk.rb:6-24`). | Read the patch; if it papers over a Wurk gap vs upstream `inline!` (e.g. `perform_in` under inline, AJ `enqueue_at`), fix to upstream behaviour + parity test. If upstream behaves the same, document only. |
| E7 | DX | `lib/wurk/testing.rb` | legald stubs `Sidekiq.redis` to raise after a missing Redis cost ~600s/CI run (`backend/test/test_helper.rb:68-74,126`). | Find the slow path (connect timeout × retries in fake mode?). Fake mode must never open a socket for push; add a unit test with an unroutable Redis URL asserting `perform_async` under `fake!` returns in <100ms. |
| E8 | DX | `lib/sidekiq/testing.rb` | `require 'sidekiq/testing'` prints a deprecation (treasury: 291 spec files rely on it; tesote.com `9ca6a72` replaced it). Upstream still supports the require. | Check upstream 8.1: if it does not warn, remove the warning (drop-in). |

## Steps
1. E1 oracle before any code. Parity rule: Wurk diverges from oracle → Wurk is wrong unless listed in `docs/idea/parity-divergences.md`.
2. E5–E8: read each adopter workaround first (paths above, read-only), reproduce in a unit test, then fix.

## Tests
- `test/parity/rails_error_reporting_test.rb` (E1), `test/parity/testing_mode_test.rb` additions (E5, E6, E8), `test/unit/testing_no_redis_test.rb` (E7).
- `bin/rake test:parity`; `bin/check`.

## Done when
- E1 oracle green on both sides or divergence recorded.
- hiscore's and legald's test workarounds are removable (verified in [`17`](17-adopter-hiscore.md), [`18`](18-adopter-legald.md)).
