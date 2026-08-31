# Wurk

**A 100% drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise. Free forever — Pro and Enterprise parity in one gem, no license check.**

On throughput Wurk is not ahead of stock Sidekiq: measured at **0.87×–1.02×** depending on workload (parity on CPU- and IO-bound jobs, behind on noop and boot). What the fork-based swarm buys is copy-on-write memory and one supervisor for multi-core, not raw speed — numbers and method in [docs/benchmarks.md](https://github.com/developerz-ai/wurk/blob/main/docs/benchmarks.md).

Wurk is wire-compatible with Sidekiq — same Redis keys, same job JSON, same Ruby DSL. Swap one line in your `Gemfile` and your existing jobs, batches, limiters, cron entries, and live Redis data keep working untouched. The Pro and Enterprise feature sets ship in the same free gem, with no license check and no tiers.

```ruby
# Gemfile
gem "wurk"
```

## Documentation

- **[[Getting Started]]** — install, the drop-in swap, your first job, mount the dashboard.
- **[[Architecture]]** — swarm, manager, fetcher, processor, client; boot order and signals.
- **[[The Dashboard]]** — mount it, secure it (Devise/Warden/Sorcery), read-only mode.
- **[[Periodic, Limiters and Batches]]** — cron, rate limiters, and batches with callbacks.
- **[[Encryption]]** — transparent AES-256-GCM argument encryption with key rotation.
- **[[Kubernetes Probes]]** — liveness/readiness for orchestration.
- **[[Migrating from Sidekiq]]** — the swap and what to expect.

## Feature matrix

Everything below is in the one free gem. The "Sidekiq tier" column shows what you'd otherwise pay for.

| Area | What you get | Sidekiq tier |
|---|---|---|
| **Runtime** | Fork-based real parallelism, reliable `BLMOVE` fetch, PID supervision, rolling restarts, graceful drain, scheduled/retry pollers | OSS + Pro |
| **Batches** | `Sidekiq::Batch` with `on(:success/:complete/:death)` callbacks, nested batches | Pro |
| **Limiters** | Concurrent, bucket, window, leaky, and points rate limiters | Enterprise |
| **Periodic** | Cron jobs, leader-elected so each tick fires exactly once across the cluster | Enterprise |
| **Encryption** | AES-256-GCM job-argument encryption with zero-downtime key rotation | Enterprise |
| **Dashboard** | Mountable Rails engine, precompiled SolidJS SPA (no Node), live SSE, charts | OSS + Pro/Ent |

## Requirements

Ruby `>= 3.2.0`, Redis `>= 7.0.0`. JRuby/TruffleRuby/Windows fall back to threads-only mode (no fork), behaviorally equivalent to stock Sidekiq.

- **Live demo:** [wurk.demo.developerz.ai](https://wurk.demo.developerz.ai)
- **Source:** [github.com/developerz-ai/wurk](https://github.com/developerz-ai/wurk)
