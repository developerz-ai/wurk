# Feature Parity Map

The implementation specs for each Sidekiq feature live in `../target/sidekiq-free.md`, `sidekiq-pro.md`, `sidekiq-ent.md`. This file maps each Sidekiq feature to the Wurk module that implements it.

## Sidekiq OSS

| Sidekiq surface | Wurk module |
|---|---|
| Sidekiq::Worker / Sidekiq::Job | Wurk::Worker (aliased back to Sidekiq::Worker) |
| Queue Redis lists | Wurk::Queue (identical key schema) |
| Retry sorted set | Wurk::RetrySet |
| Scheduled sorted set | Wurk::ScheduledSet |
| Dead sorted set (capped) | Wurk::DeadSet |
| Middleware client + server chains | Wurk::Middleware::Chain |
| Sidekiq.configure_server / configure_client | Same names, aliased |
| Web UI | Wurk::Web (mounted at /wurk; alias /sidekiq if requested) |
| Stats counters | Wurk::Stats (identical keys) |
| Process heartbeat set | Wurk::Heartbeat |

## Sidekiq Pro

| Pro feature | Wurk module |
|---|---|
| Reliable fetch (super_fetch) | Wurk::Fetcher::Reliable — the default fetcher, BLMOVE-based |
| Reliable client (Redis-outage buffer) | Wurk::Client::Buffered |
| Batches and callbacks | Wurk::Batch and Wurk::Batch::Status |
| Queue pause/resume | Wurk::Queue pause / resume API |
| Job expiry (expires_in) | sidekiq_options key honored |
| Statsd metrics | Wurk::Metrics::Statsd |
| Lua fast API | Wurk::Lua (bulk enqueue, multi-pop) |
| Web UI search | Wurk::Web::Search |

## Sidekiq Enterprise

| Ent feature | Wurk module |
|---|---|
| Rate limiters (concurrent, window, bucket, unlimited) | Wurk::Limiter |
| Periodic jobs | Wurk::Cron |
| Leader election | Wurk::Leader (Redis SETNX + fencing token) |
| Unique jobs | Wurk::Unique (until_executed / until_executing / until_and_while_executing) |
| Encryption | Wurk::Encryption (AES-256-GCM, key rotation) |
| Historical metrics | Wurk::Metrics::History (time-series in Redis) |
| Multi-process swarm | Wurk::Swarm — built into the gem |
| Rolling restarts | Wurk::Swarm rolling-restart on SIGUSR1 |
| Enterprise Web UI panes | Wurk::Web::Enterprise (limiters, cron, metrics) |

## Wurk-only

| Feature | Why it's worth adding |
|---|---|
| Worker topology DSL | Stronger queue isolation than Ent's flat swarm |
| AI dashboard panes | Anomaly detection, NL queries, backlog forecasting |
| Mountable engine | One deploy, no separate worker process needed |
| Precompiled assets | Consumers never run Node — see 09-precompiled-assets.md |
| Dummy app | First-class engine integration testing — see 10-dummy-app.md |
| Minitest parallel helpers | Per-test Redis namespace isolation, multi-CPU |
