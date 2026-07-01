# Roadmap

Ship parity incrementally. Every milestone produces a usable gem.

## M0 — Skeleton

- Gemspec, engine class, version, MIT license.
- Dummy Rails app under `test/dummy/` boots.
- Minitest parallel runner configured.
- Blacksmith CI workflow green on a smoke test.
- VitePress docs site scaffolded and published to GitHub Pages.

## M1 — Core processor

- Wurk::Worker plus perform_async, perform_in, perform_at.
- Redis schema matching Sidekiq OSS — queue lists, schedule zset, retry zset, dead zset.
- Reliable BLMOVE fetcher.
- Manager thread pool.
- Fork-based swarm with SIGTERM graceful drain.
- Sidekiq compat aliases so existing apps work unchanged.
- Acceptance: existing Sidekiq jobs in a real Redis run untouched.

## M2 — Web dashboard parity

- Engine mounted at `/wurk`.
- Precompiled SolidJS SPA bundle baked into the gem.
- Parity panes: dashboard, queues, retries, scheduled, dead, busy.
- SSE live updates.

## M3 — Pro parity

- Batches and callbacks.
- Reliable client with Redis-outage buffer.
- Queue pause and resume.
- Job expiry option.
- Statsd metrics emitter.
- Web UI search.

## M4 — Enterprise parity

- Rate limiters (concurrent, window, bucket).
- Cron with leader election (fencing token).
- Unique jobs (until_executed, until_executing, until_and_while_executing).
- Encryption (AES-256-GCM with key rotation).
- Historical metrics (time-series).
- Rolling restart logic on SIGUSR1.

## M5 — AI dashboard

- Anomaly detection.
- Natural-language queue queries.
- Error triage clustering.
- Capacity advisor.

## M6 — 1.0

- Migration guide finalized.
- Benchmark suite published with comparisons to stock Sidekiq.
- Full YARD API reference auto-generated to the docs site.
- Tag 1.0.0, push to RubyGems.

## Stretch (post-1.0)

- Worker topology DSL (specialized swarm slots).
- io_uring fetch path on Linux.
- ActiveJob adapter beyond the default.
- Helm chart and Kubernetes operator.
