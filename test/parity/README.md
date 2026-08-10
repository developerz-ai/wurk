# Parity tests

Independently written oracles for the Sidekiq surface Wurk implements. They are
**not** copies of upstream Sidekiq's test files — they assert the documented
behaviour using Wurk's own helpers and class names.

`.sidekiq_sha` pins the upstream commit whose *documented behaviour* these
oracles were written against, so a maintainer can tell which version of the
surface a given assertion targets.

These tests are **oracles**. When Wurk diverges from a parity test, Wurk is wrong unless the divergence is explicitly documented as intentional in `docs/target/sidekiq-{free,pro,ent}.md`.

Run: `bin/rake test:parity`

To add a test:
1. Write it from the documented behaviour — `docs/target/sidekiq-{free,pro,ent}.md` and the [Sidekiq wiki](https://github.com/sidekiq/sidekiq/wiki). Do not copy upstream test files; Sidekiq is LGPL-3.0 and this repository is MIT.
2. Assert against the observable contract: payload fields, encodings, Redis key shapes, return values. Use the `Sidekiq::*` aliases, since that is what a drop-in app sees.
3. Head the file with the spec section it enforces, so a divergence is traceable to a documented promise rather than to an implementation detail.

To bump the Sidekiq SHA:
1. Find the upstream Sidekiq commit SHA and date from https://github.com/sidekiq/sidekiq/commits/main.
2. Review the behaviour changes in the interval; update `docs/target/*.md` where the documented surface moved.
3. Update `sha` and `date` in `.sidekiq_sha`.
4. Run `bin/rake test:parity` to verify the oracles still pass.
5. Commit with a message like "pin parity oracle: sidekiq@e1f808a".
