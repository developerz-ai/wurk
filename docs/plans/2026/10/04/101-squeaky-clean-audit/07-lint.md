# 07 — Lint stability + config (closes #471, #477)

> Part of [`overview.md`](overview.md). Depends on: [`05`](05-ci-gates.md) C3 (lint runs on `.rubocop.yml` PRs). #471 before #477 — both touch `.rubocop.yml`; the pin guarantees rubocop ≥1.78 for `AllowBangMethods`.

## #471 — rubocop release reddens main with no PR at fault

- Root cause: `Gemfile:19` unpinned `rubocop`; `.rubocop.yml:3` `NewCops: enable`; `.gitignore:5` ignores `Gemfile.lock`.
- Steps: pin `rubocop`, `rubocop-minitest`, `rubocop-rake` `~> X.Y.0` at `Gemfile:19-21` (current local: 1.90.0); dependabot bundler entry (`.github/dependabot.yml:9-20`) then opens scheduled bumps. Why-comment beside pin + `NewCops`. Fix misplaced SimpleCov comment in `Gemfile` (sits above rubocop gems).
- Tests: `bundle exec rubocop --parallel` clean.

## #477 — 35 inline `Naming/PredicateMethod` disables → config

- State: valid (35 confirmed); last bot comment says NEEDS-SPEC → re-triage / human "go" ([`11`](11-human-actions.md)).
- Steps: block after `Naming/VariableNumber` (`.rubocop.yml:97-100`): `Include:` scoped to files w/ cited sites; `AllowedPatterns: ['\Await_(for|until)']`; `AllowBangMethods: true`; `AllowedMethods:` spec-fixed Sidekiq names; `inherit_mode: {merge: [AllowedMethods]}`. Never `Enabled: false`. Delete directives at allowlisted sites; keep the non-spec ones listed in issue (`buffered.rb:534`/`:154`, `restart.rb:56`, `enterprise.rb:173`, `dead_set.rb:55`, `flow.rb:179`, `leader.rb:92`, `queue_slot.rb:205`/`:223`).
- Tests: `rubocop --show-cops Naming/PredicateMethod`; throwaway `def frobnicate; 1 == 1; end` → exactly one offense; zero overall; `bin/check`.

## Follow-up (same slice, separate PR)
- 13 `rescue Exception` inline disables (`Lint/RescueException`) in `lib/` — review each: legit only at thread top-levels that must survive (processor/manager loops) and must re-raise `SignalException`/`SystemExit` where appropriate. Cross-check with [`02`](02-core-runtime.md) findings.
- 15 `Lint/MissingSuper` — confirm intentional.

## Done when
- #471, #477 closed. Inline disable count in `lib/` drops from 71 by ≥35.
