# Migrating from Sidekiq

```diff
- gem "sidekiq"
- gem "sidekiq-pro", source: "https://gems.contribsys.com/"
- gem "sidekiq-ent", source: "https://enterprise.contribsys.com/"
+ gem "wurk"
```

Then `bundle install && restart`. Your job classes, initializers, and live Redis data are untouched.

## Why it just works

Wurk reads and writes the **same Redis schema** Sidekiq does — same keys, same job JSON, same sorted-set score formats. So:

- Jobs already enqueued under Sidekiq run on Wurk unchanged.
- No data migration. Running Sidekiq and Wurk workers on one Redis at the same time is tested for stock Sidekiq 8 only (no Pro, no Enterprise), which may roll under the conditions in the guide's rolling-cutover note; any other app cuts over by draining (stop Sidekiq's workers, confirm nothing is in flight, start Wurk). See the production cutover section of docs/migrate-from-sidekiq.md.
- Every public `Wurk::*` class is exposed under its `Sidekiq::*` name, so `Sidekiq::Worker`, `Sidekiq::Batch`, `Sidekiq::Limiter`, `Sidekiq.configure_server` all resolve.
- Rollback is the same drain in reverse, plus confirming Wurk's `queue:*|*` private lists are empty before Sidekiq starts. No schema change was made.

## The one thing that needs real thought: processes × threads

This is the #1 source of migration surprises. Sidekiq is one process with a thread pool. Wurk is **a swarm of forked processes, each with its own thread pool** — two independent knobs:

| Knob | Controls | Set with | Default |
|---|---|---|---|
| Parallelism | forked worker **processes** | `WURK_COUNT` (alias `SIDEKIQ_COUNT`) | CPU core count |
| Concurrency | **threads** per process | `config.concurrency`, `-c`, `RAILS_MAX_THREADS` | 5 |

Jobs in flight is the **product**, and so is your resource usage:

```text
16-core box, defaults:  16 processes × 5 threads = 80 jobs in flight
                                                 + 16 separate DB connection pools
```

A box that happily ran `concurrency: 25` in one Sidekiq process becomes 16 × 25 = 400 database connections. Map your old number deliberately — a Sidekiq `concurrency: 10` app matches at `WURK_COUNT=2` with `concurrency = 5` — and size `pool` in `database.yml` per process.

There is **no `WURK_CONCURRENCY`** env var, and `WURK_COUNT` only applies to the forking runners (`wurkswarm` and the Rails engine's auto-boot swarm). Plain `bundle exec wurk` is a single process.

## Gotchas worth knowing before you cut over

- **Set `WURK_DISABLED=1` on the web role.** Under clustered Puma (or Unicorn, Passenger) the engine refuses to fork a swarm and logs a warning, so that process runs no jobs; `WURK_DISABLED=1` silences it once workers run elsewhere.
- **`sentry-sidekiq` installs only with the `sidekiq` shim gem** (its gemspec depends on `sidekiq`; without the shim Bundler pulls real Sidekiq in beside Wurk). Its suite runs against Wurk in CI, but the native `require "wurk/sentry"` is preferred.
- **`Sidekiq.pro?` / `Sidekiq.ent?` return `false`** even though the Pro and Enterprise features are all present. Don't gate behaviour on them.
- **`config.super_fetch!` is an accepted no-op** — reliable fetch is already the only mode. `config.reliable_scheduler!` is *not* a no-op, and it is optional: it swaps in an atomic Lua promoter that skips client middleware.
- **Unique jobs and encryption are mutually exclusive on the same worker**: ciphertext differs per encryption, which defeats the uniqueness digest.

## Gems you can probably delete

`sidekiq-cron` → `config.periodic`. `sidekiq-unique-jobs` → `unique_for:` / `unique_until:`. `sentry-sidekiq` → `Wurk::Sentry`. Batches, rate limiters, and encryption are built in, so `sidekiq-pro` and `sidekiq-ent` go too. Gems you keep are covered under [[Compatibility and Divergences]] — `sidekiq-cron`, `sidekiq-unique-jobs`, `sidekiq-failures` and `sentry-sidekiq` run their own suites against Wurk in CI (exclusions in `test/ecosystem/README.md`), through the `sidekiq` shim gem.

## Cutover checklist

1. Swap the gem, `bundle install`.
2. Choose `WURK_COUNT` × `concurrency`, then check DB pool and memory against the product.
3. Re-point the dashboard route: `mount Wurk::Engine => "/wurk"`, behind your app auth.
4. Split web from workers — dedicated `wurkswarm`, `WURK_DISABLED=1` on web.
5. Enqueue a test job against the same Redis, watch it run, compare the dashboard to your existing `redis-cli` checks.
6. Roll one process at a time; revert the `Gemfile` line if anything looks wrong.

Full guide — per-option mapping, `config.redis` keys, runner comparison, Puma topology, and the complete incompatibility list: **[docs/migrate-from-sidekiq.md](https://github.com/developerz-ai/wurk/blob/main/docs/migrate-from-sidekiq.md)**.
