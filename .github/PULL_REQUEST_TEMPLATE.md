<!-- Thanks for contributing to Wurk! Keep PRs focused. -->

## What & why

<!-- What does this change, and what problem does it solve? Link the issue: Closes #123 -->

## Checklist

- [ ] Tests added/updated at the right layer (unit · engine · integration · parity)
- [ ] `bin/rake test`, `bin/rake test:parity`, and `bundle exec rubocop` pass locally
- [ ] No Redis key, JSON field, or sorted-set score format changed (wire-compat is sacred)
- [ ] Public Sidekiq surface still matches `docs/target/sidekiq-{free,pro,ent}.md`
- [ ] Coverage on `lib/` stays ≥ 90%

## How to test in prod

<!-- Copy-paste operator commands a maintainer can run to verify this in a real deploy. -->
