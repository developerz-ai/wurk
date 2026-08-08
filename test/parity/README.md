# Parity tests

Tests lifted from upstream Sidekiq's own suite, SHA-pinned in `.sidekiq_sha`.

These tests are **oracles**. When Wurk diverges from a parity test, Wurk is wrong unless the divergence is explicitly documented as intentional in `docs/target/sidekiq-{free,pro,ent}.md`.

Run: `bin/rake test:parity`

To add a test:
1. Copy it verbatim from upstream Sidekiq at the SHA in `.sidekiq_sha`.
2. Adapt only the `require` lines (point at Wurk) and assertions about class names (use `Sidekiq::*` aliases so the rest of the body is untouched).
3. If you have to change the *assertions* themselves, you are diverging — open an issue first.

To bump the Sidekiq SHA:
1. Find the upstream Sidekiq commit SHA and date from https://github.com/sidekiq/sidekiq/commits/main.
2. Update `sha` and `date` in `.sidekiq_sha`.
3. Run `bin/rake test:parity` to verify all lifted tests still pass.
4. Commit with a message like "pin parity oracle: sidekiq@e1f808a".
