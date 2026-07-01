# Wurk — Seed

100% API-compatible drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise. Free forever. Meaningfully faster. Like AOSP for Sidekiq.

## The pitch in one sentence

**Same Sidekiq API, includes all Pro + Enterprise features for free, runs faster.**

## Three pillars (all must be true)

1. **100% drop-in.** Same Ruby API, same Redis wire format, same DSL. Migration is a one-line gem swap. Third-party gems built on Sidekiq (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-status, etc.) work unchanged. We prove this in CI by running each ecosystem gem's own test suite against Wurk.
2. **Free.** Pro + Enterprise feature parity built in. No license tiers, no paid features.
3. **Faster.** Real multi-process parallelism via fork. Optimized Redis path. Precompiled assets. Hot loops tuned. Every release benchmarked against stock Sidekiq; regressions block merge.

## Shape

- Mountable Rails engine. Host app mounts wherever it wants — Wurk doesn't force a path.
- Forks workers after the host app boots, copy-on-write memory savings.
- Ships precompiled dashboard assets — no Node toolchain required by consumers.
- Includes a dummy Rails app at `test/dummy/` for engine integration testing.
- Modern dashboard: right-side menu, mobile-friendly, dark + light themes, i18n with extensible locales.
- Minitest with multi-CPU parallel runner.
- GitHub Actions on Blacksmith runners.
- Public docs site on GitHub Pages.

## Doc index

| File | Topic |
|---|---|
| 01-overview.md | What Wurk is, the three pillars |
| 02-architecture.md | High-level layers and process tree |
| 03-process-model.md | Fork-based swarm, worker topology, supervision |
| 04-signals.md | Graceful drain, rolling restart, crash safety |
| 05-features.md | Parity map: Sidekiq OSS / Pro / Ent → Wurk modules |
| 06-performance.md | Every optimization, with rationale |
| 07-rails-engine.md | Mountable engine, configurable mount point |
| 08-dashboard.md | SolidJS SPA, right-side menu, mobile, dark theme, i18n, AI |
| 09-precompiled-assets.md | Assets baked into the gem at build time |
| 10-dummy-app.md | `test/dummy/` Rails app for engine tests |
| 11-testing-ci.md | Minitest parallel + Blacksmith GitHub workers |
| 12-docs-site.md | GitHub Pages docs site |
| 13-roadmap.md | MVP → 1.0 sequencing |
| 14-ecosystem-compat.md | Tests against sidekiq-cron, sidekiq-unique-jobs, etc. |
| ../target/sidekiq-free.md | OSS Sidekiq API spec to implement |
| ../target/sidekiq-pro.md | Sidekiq Pro API spec to implement |
| ../target/sidekiq-ent.md | Sidekiq Enterprise API spec to implement |
