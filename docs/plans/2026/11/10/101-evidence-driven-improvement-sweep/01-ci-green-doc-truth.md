# 01 — CI green + doc truth

> Part of [`overview.md`](overview.md). Depends on: none. One PR. Do first: `main` is red.

## Files to change
| ID | Where | Change |
|---|---|---|
| C1 | `.github/workflows/test.yml:470-495` (python-client matrix); `clients/python/pyproject.toml` | `ubuntu-latest` has no Python 3.9 → leg red on every `main` push since 2026-11-07 (`gh run list --workflow test --branch main --status failure`). Matrix `["3.10","3.13"]`, `fail-fast: false`, `requires-python >=3.10`. |
| C2 | ecosystem release-watcher workflow (grep `DEVELOPERZ_API_KEY` in `.github/workflows/`) | Scheduled run fails when the secret is absent. Skip with a `::notice::` instead of failing, or add the secret ([`13`](13-human-decisions.md) U2). |
| C3 | `docs/wiki/Migrating-from-Sidekiq.md:43-46` | 3 false lines: "clustered Puma forks a duplicate swarm" (code refuses: `lib/wurk/rails_boot.rb:134,257-273`); "`sentry-sidekiq` cannot be installed" (installs with the shim; CI suite green); `reliable_scheduler!` "keep it" vs main guide "optional". Align to `docs/migrate-from-sidekiq.md`. |
| C4 | `docs/sentry.md:16` | "cannot be installed alongside Wurk" → "installs only with the shim; native `Wurk::Sentry` preferred". |
| C5 | `docs/migrate-from-sidekiq.md:444` and §10 table | Says only sidekiq-cron runs its upstream suite (4 do: `docs/idea/14-ecosystem-compat.md`); says dashboard "does not render ERB extensions" (`docs/dashboard.md:114-135` says it does). Verify the cron tab in `bin/dev`, fix whichever is wrong. |
| C6 | `docs/idea/14-ecosystem-compat.md` | sidekiq-status blocker stale: `Sidekiq::WebHelpers` exists (`lib/wurk/compat.rb:122`), `SAFE_QPARAMS` mutable (`lib/wurk/web/helpers.rb:14`). Remaining blocker = ERB `web_spec` only. |
| C7 | `docs/api-http.md` "Versioning" | Example `"wurk_version": "8.4.0"` → placeholder; `lib/wurk/api/app.rb:114` returns `Wurk::VERSION`. |
| C8 | `lib/generators/wurk/install/templates/wurk.rb:4,~21` | Cites `docs/target/sidekiq-free.md`, `docs/idea/03-process-model.md` — not shipped in the gem. Full GitHub URLs to `docs/configuration.md`, `docs/deployment.md`. |
| C9 | `lib/wurk/api/validation.rb:97` | `# rubocop:disable-next` is not a directive. Real disable/enable pair. |
| C10 | `docs/unique-jobs.md:424` | Remove "There is no warning" once [`03`](03-boot-guards-preflight.md) G1 lands (same PR as G1, not this one). |

## Steps
1. C1 first, alone if needed, to turn `main` green.
2. C3–C8 in one docs PR. Extend the existing claims guards (`test/unit/*_claims_test.rb`) to cover `docs/wiki/` for the three C3 strings.
3. C9 with any `lib/` PR; run `bin/repin-anchors` if anchors move.

## Tests
- `bin/check fast`; `bin/rake test TEST=test/unit/ai_config_test.rb`; claims tests.
- `gh run watch` on the PR: both python legs report.

## Done when
- `gh run list --workflow test --branch main --limit 3` all success.
- `grep -rn "cannot be installed" docs/` returns nothing; wiki claims test green.
