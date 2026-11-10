# 17 — Adopter repo: hiscore/hiscore.ro

> Part of [`overview.md`](overview.md). Depends on: Wurk release with [`05`](05-errors-and-test-mode.md), [`11`](11-observability-ops.md) K1. Edited from `~/workspace/hiscore/hiscore.ro`.

## Files to change
| ID | Where | Change |
|---|---|---|
| S1 | `lib/capistrano/tasks/wurk.rake` (109 lines; unit has `RestartSec=1`, no `StartLimit*`) | Replace unit body with Wurk's shipped `examples/systemd/wurk.service`; add `wurk health` as `ExecStartPost` check or a timer. |
| S2 | `config/initializers/wurk.rb:40-51` (`config.topology` under single-process `wurk`) | Drop it or switch the unit to `wurkswarm`; today it is ignored. |
| S3 | `spec/support/wurk.rb:6-24` (monkeypatches `perform_async`/`perform_in`/AJ enqueue); `config/initializers/wurk.rb:16-22` (`unique!` skipped in test) | Remove after [`05`](05-errors-and-test-mode.md) E5/E6. |
| S4 | `config/application.rb:22-29` (`require 'wurk/engine'`) | Remove only if `wurk boot-check` passes without it. |
| S5 | `config/initializers/wurk.rb:59-64` (`schedule.yml` loader) | As gringotts S2. |
| S6 | Bugsnag | Confirm job failures arrive (trigger one in staging); wire `error_handlers` explicitly if not. |

## Done when
- Deploy log shows the new unit; a deliberate crash loop backs off instead of restarting every 1s.
