# 16 — Adopter repo: tesote/gringotts-wizarding-bank

> Part of [`overview.md`](overview.md). Depends on: Wurk release. Edited from `~/workspace/tesote/gringotts-wizarding-bank` (`git pull` first; remote on 1.11.0).

## Files to change
| ID | Where (under `rails/`) | Change |
|---|---|---|
| S1 | CI | `wurk boot-check` (would have caught `cc2a24fc` Dotenv load order). |
| S2 | `config/initializers/wurk/2periodic.rb:26-45` (hand-rolled `schedule.yml` loader) | Move to lid-stable `load_file` once [`11`](11-observability-ops.md) K4 ships; verify lids unchanged with `wurk verify` before/after. |
| S3 | `:timeout: 25` vs 900s grace | Size per [`11`](11-observability-ops.md) K3 table. |
| S4 | infra probe — [`19`](19-infra-tesote.md) | `ps \| grep` → `wurk health`. |
| S5 | `config/initializers/wurk/1default.rb:37-49`, `sentry.rb:9-28`, `config/application.rb:45` | Remove per `removable-workaround:` notes. |

## Done when
- Loop lids identical before/after S2 (`wurk verify` output diff empty).
