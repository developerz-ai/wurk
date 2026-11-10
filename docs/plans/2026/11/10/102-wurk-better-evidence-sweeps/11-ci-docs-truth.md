# 11 — CI health, anchors ledger, doc truth

> Part of [`overview.md`](overview.md). Depends on: none. C1 is day-zero.

Read `.github/CLAUDE.md` before touching workflows. Required checks: never re-declare — `gh api repos/developerz-ai/wurk/rulesets` is the authority.

## Files to change

| ID | Pri | Where | Problem | Change |
|---|---|---|---|---|
| C1 | P0 | `.github/workflows/test.yml:470-495` (`python-client` matrix `["3.9","3.13"]`), `clients/python/pyproject.toml` | `main` red on every run since 2026-11-07: Python 3.9 unavailable on the current `ubuntu-latest`; 3.13 leg cancelled (no `fail-fast: false`). Verify current state first: `gh run list --workflow test.yml --branch main --limit 5`. | Matrix `["3.10","3.13"]`, `fail-fast: false`, `requires-python >=3.10`. |
| C2 | P2 | `.github/workflows/ecosystem.yml` (scheduled "sidekiq release watcher") | Fails on missing `DEVELOPERZ_API_KEY` secret. | Skip with a notice when the secret is absent. |
| C3 | P2 | `docs/idea/parity-divergences.md` (89 `#L` anchors), `test/conformance/`, `bin/repin-anchors` | 22 of 65 `lib/` commits since 2026-09-01 also had to touch the ledger/conformance pins; every slice in this plan will too. | Anchor on symbols (`file#Class#method` or a quoted fragment — direction started in #865) instead of line ranges; `bin/repin-anchors --check` verifies symbol existence. Land **before** the large `lib/` slices (03, 10) to stop paying the tax. |
| C4 | P2 | `.github/workflows/test.yml:383-402` (Rails 7.1 + 8.1 only), `README.md:161-170`, `active_job/queue_adapters/wurk_adapter.rb:11`, `docs/active-job.md:73` | Docs/adapter say `activejob >= 7.0`; CI covers 7.1, 8.1. | State "tested 7.1 and 8.1; floor 7.1" (raise the floor), or add legs — pick by cost; note in CHANGELOG. |
| C5 | P2 | `docs/active-job.md`, `test/engine/` | Rails 8.1 `ActiveJob::Continuable` unmentioned though `stopping?` exists (`wurk_adapter.rb:69`); per-job `enqueue_after_transaction_commit` on 8.x unverified. | Engine test: continuation resumes across quiet/restart; verify 8.x deprecation path of the adapter-level method; doc rows. |
| C6 | P2 | docs sweep, one PR | Contradictions: `docs/wiki/Migrating-from-Sidekiq.md:43` (clustered Puma "forks a duplicate swarm" — code refuses, `rails_boot.rb:129-134,257`), `:44` + `docs/sentry.md:16` (sentry-sidekiq "cannot be installed" — its suite is green in CI via the shim), `:46` (`reliable_scheduler!` "keep it" vs guide "optional"); `docs/api-http.md:192` (`8.4.0`); `docs/target/sidekiq-ent.md:847` stale line link; `docs/conformance.md:164` dead link; `bench/memory.rb:25` says ">5% blocks merge" vs advisory gate (CLAUDE.md). | Fix each. Extend the existing `*_claims_test` guards (`test/unit/`) to cover `docs/wiki/`. |
| C7 | P3 | `lib/wurk/api/validation.rb:97` | `# rubocop:disable-next Style/MutableConstant` — not a RuboCop directive. | Correct directive or delete. |
| C8 | P3 | `clients/python/` | 0.1.0, unpublished, no swarm/health reads. | After W13: publish via trusted publishing = H10. |
| C9 | P3 | `docs/` new page | No migration stories from Solid Queue / GoodJob / Resque / DelayedJob. | Short "from Active Job backends" page: switch adapter, drain old backend, map recurring config. Only what is tested in `test/engine`. |
| C10 | P3 | `CLAUDE.md` (11,522 / 12,000 chars; `test/unit/ai_config_test.rb`) | ~480 chars headroom; this plan adds commands (`wurk boot-check`, `bench:soak`, `bench:scale`). | Put new detail in `lib/CLAUDE.md` / `test/CLAUDE.md` / `.github/CLAUDE.md`, not the root. |

## Steps
1. C1 immediately, alone.
2. C3 next (unblocks cheap `lib/` PRs); then C6 + C7 + C2; C4/C5; C9; C8 after W13 + H10.
3. Workflow edits: `actionlint` + `zizmor` per `.github/CLAUDE.md`.

## Tests
- C1: `gh run watch` on the PR; main green after merge (verify, don't assume: `gh run list --workflow test.yml --branch main --limit 3`).
- C3: `bin/repin-anchors --check` green after an unrelated line-shifting edit in an anchored file (prove the tax is gone).
- C6: extended claims test fails on the old wiki wording.

## Done when
- `main` green; no scheduled workflow fails for a missing secret.
- A `lib/` PR that only shifts lines needs no ledger edit.
- No doc contradicts CI, the code, or another doc on: Puma cluster, sentry-sidekiq, `reliable_scheduler!`, Rails floor, bench gate.
