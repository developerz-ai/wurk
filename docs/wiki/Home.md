# Wurk

**A 100% drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise. Free forever — Pro and Enterprise parity in one gem, no license check.**

Same Redis keys, same job JSON, same Ruby DSL. Swap one line in your `Gemfile` and your existing jobs, batches, limiters, cron entries, and live Redis data keep working untouched.

```ruby
# Gemfile
gem "wurk"   # remove sidekiq, sidekiq-pro, sidekiq-ent
```

On throughput Wurk is not ahead of stock Sidekiq: measured at **0.87×–1.02×** depending on workload (parity on CPU- and IO-bound jobs, behind on noop and boot). What the fork-based swarm buys is copy-on-write memory and one supervisor for multi-core, not raw speed — numbers and method in [docs/benchmarks.md](https://github.com/developerz-ai/wurk/blob/main/docs/benchmarks.md).

Try it before installing anything: **[wurk.demo.developerz.ai](https://wurk.demo.developerz.ai)** runs the real dashboard against a live swarm.

## Start here

- **Evaluating Wurk?** [[Compatibility and Divergences]] — will your exact setup work — and [[Performance]] for the honest numbers.
- **Installing it?** [[Getting Started]] — first job and the dashboard, in ten minutes.
- **Running it?** [[Architecture]] — processes, boot order, and what each signal does.

## The pages

| Page | What it covers |
|---|---|
| [[Getting Started]] | Install, the drop-in swap, your first job, mounting the dashboard |
| [[Migrating from Sidekiq]] | The one-line swap, sizing processes × threads, the cutover checklist |
| [[Compatibility and Divergences]] | What is identical, what deliberately differs, ecosystem gem status |
| [[Performance]] | The measured 0.87×–1.02× position and what forking actually buys |
| [[Configuration]] | The initializer, precedence, the options and env vars you will actually set |
| [[Running and Deployment]] | The two runners, signals, rolling restarts, zero-downtime deploys |
| [[Testing]] | The three modes, and what inline execution silently skips |
| [[Active Job]] | The adapter, the zero-edit `:sidekiq` path, wire compatibility |
| [[Architecture]] | Swarm, manager, fetcher, processor, client; boot order and signals |
| [[The Dashboard]] | Mount it, secure it (Devise/Warden/Sorcery), read-only mode |
| [[Periodic, Limiters and Batches]] | Cron, the five rate limiters, batches with callbacks |
| [[Encryption]] | Transparent AES-256-GCM argument encryption with key rotation |
| [[Kubernetes Probes]] | Liveness and readiness endpoints for orchestrators |

These are **orientation** pages: what a thing is, the smallest working example, the gotchas. The full reference — 30 documents covering every option, adapter, and API — lives in [docs/](https://github.com/developerz-ai/wurk/tree/main/docs) on `main`, and each page links its own.

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
- **Docs site:** [developerz-ai.github.io/wurk](https://developerz-ai.github.io/wurk/) · [API reference](https://developerz-ai.github.io/wurk/api/)
- **Source:** [github.com/developerz-ai/wurk](https://github.com/developerz-ai/wurk)
