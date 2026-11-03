# lib/ — layers and ownership

One reason to change per class. Don't blur these. Each class's header comment is the detail; this is the map.

| Layer | Owns | Path |
|---|---|---|
| Engine | Dashboard mount, asset path | `lib/wurk/engine.rb`, `app/` |
| Railtie | Rails hooks only (config namespace, server_mode initializer, reloader install, last-Finisher initializer that starts the swarm); every boot decision is delegated | `lib/wurk/railtie.rb` |
| RailsBoot | Boot policy: whether this process boots, whether it forks, embeds or refuses, server-mode entry | `lib/wurk/rails_boot.rb` |
| Swarm | Parent process; forks N children, PID supervision, rolling restart | `lib/wurk/swarm.rb`, `lib/wurk/swarm/` |
| Topology | Worker-topology slot DSL (count/queues/concurrency per fork kind); Swarm consumes its `assignments` | `lib/wurk/topology.rb` |
| Launcher | Top-level supervisor inside each worker process: Manager pool (one per Capsule), scheduler poller, heartbeat thread | `lib/wurk/launcher.rb` |
| Capsule | One processing unit: a set of threads + queues sharing a fetcher and a Redis pool | `lib/wurk/capsule.rb` |
| Manager | Runs one Capsule: Processor pool, replace-on-die, quiet/stop lifecycle. Not the heartbeat | `lib/wurk/manager.rb` |
| Fetcher | Abstract base; `Fetcher::Reliable` is the shipped implementation: `LMOVE`/`BLMOVE` main queue → per-process private list, ACK held and pipelined with the next fetch. Supporting: `capped.rb` (global concurrency caps), `many_queues.rb` (one-round-trip multi-queue claim), `unit_of_work.rb` (ACK/requeue), `reaper.rb` + `private_list_key.rb` + `orphan_grace.rb` + `unparseable_keys.rb` (orphan reclamation) | `lib/wurk/fetcher.rb`, `lib/wurk/fetcher/` |
| Processor | Takes a UnitOfWork from the capsule's fetcher, parses once, runs the middleware chain, invokes perform, ACKs | `lib/wurk/processor.rb` |
| Client | Enqueue, Lua bulk path, Redis-outage local buffer | `lib/wurk/client.rb`, `lib/wurk/client/` |
| Middleware | Client + server chains (Sidekiq contract) | `lib/wurk/middleware/` |
| Web | Engine-mounted SolidJS SPA (`app/controllers/wurk/dashboard_controller.rb`) and dashboard JSON (`api_controller.rb` via `Wurk::Api::Serializers` in `app/controllers/wurk/api/`). `Wurk::Web` itself holds config, authorization, search. Its class-level Rack entry serves extension routes; under `mount Sidekiq::Web` in a Rails app every other path goes to the engine, and as a bare Rack app they 404 | `lib/wurk/web.rb`, `lib/wurk/web/`, `app/` |
| API | Machine-facing HTTP API, versioned `/v1`, plain Rack with no Rails reference — one implementation serves all three mounts: engine-nested `<mount>/api/v1`, separately mounted `mount Wurk::API => '/wurk-api'`, standalone `run Wurk::API`. `Wurk::API::Serializers` is not `Wurk::Api::Serializers`. The namespace also holds API::Fast, the Pro data-API Lua extensions | `lib/wurk/api.rb`, `lib/wurk/api/` |
| Compat | Sidekiq-alias layer (`Sidekiq::*` namespace — the drop-in contract) and the `require "sidekiq"` entrypoint | `lib/wurk/compat.rb`, `lib/sidekiq.rb` |
| RedisPool | Per-process pool over redis-client | `lib/wurk/redis_pool.rb` |
| Configuration | Runtime knobs, lifecycle/error/death handler registries and Capsule registry; supplies boot settings, not process supervision | `lib/wurk/configuration.rb` |
| Worker / Job DSL | Job options, enqueue methods, retry hooks and instance helpers; delegates enqueue to Client and execution to Processor | `lib/wurk/worker.rb` |
| IterableJob | Resumable iteration loop, cursor checkpoints and cooperative interruption; owns `perform`, while user jobs implement `each_iteration`, not processor lifecycle | `lib/wurk/iterable_job.rb` |
| CLI / Embedded | Standalone argument/config loading and boot entrypoints (worker, `run_swarm`, `run_api`); Embedded starts the Launcher stack inside a host Ruby process without swarm supervision. Neither requires the Rails engine | `lib/wurk/cli.rb`, `lib/wurk/embedded.rb` |
| Scheduled | Polling and promotion of due `retry` / `schedule` entries through Client; not retry policy or periodic cron registration | `lib/wurk/scheduled.rb` |
| Cron | Periodic registration, cron parsing and leader-gated enqueue ticks; creates periodic work rather than promoting delayed jobs | `lib/wurk/cron.rb` |
| Leader | Best-effort Redis lease election and fencing token; not strict mutual exclusion, so consumers needing it must guard their writes | `lib/wurk/leader.rb` |
| Heartbeat | Redis process/work heartbeat schema, slot refresh and queued-signal reads; returns signals to Launcher, which retains lifecycle and signal dispatch | `lib/wurk/heartbeat.rb` |
| JobRetry | Failure policy, backoff, retry metadata, exhaustion hooks and dead-set routing; Scheduled later promotes retries, Processor still owns execution | `lib/wurk/job_retry.rb` |
| Redis data views | Ruby inspection and mutation of queues and job sets, plus stats, live processes and work snapshots; not the machine-facing HTTP API or dashboard Web transport | `lib/wurk/queue.rb`, `lib/wurk/job_set.rb`, `lib/wurk/stats.rb`, `lib/wurk/process_set.rb`, `lib/wurk/work_set.rb` |
| Batch | Job-group progress, nested completion tracking and success/complete/death callbacks; integrates with enqueue and execution middleware rather than owning dispatch | `lib/wurk/batch.rb`, `lib/wurk/batch/` |
| Flow | DAG dependency composition with one Batch per node; reuses Batch completion tracking, not a second completion ledger | `lib/wurk/flow.rb` |
| Limiter | Lua-backed resource/rate acquisition, waiting and OverLimit rescheduling middleware; not enqueue deduplication or per-queue fetch caps | `lib/wurk/limiter.rb`, `lib/wurk/limiter/` |
| Unique | Best-effort enqueue deduplication locks and their success/start/death release policy; rejects duplicates rather than replacing pending work or rate-limiting execution | `lib/wurk/unique.rb` |
| Collapse / Debounce / Throttle | Collapse validates/routes worker policies; Debounce replaces a pending scheduled payload until quiet, Throttle drops extras per fixed time slot. Distinct from Unique locks and Limiter resource budgets | `lib/wurk/collapse.rb`, `lib/wurk/debounce.rb`, `lib/wurk/throttle.rb` |
| QueueSlot | Global per-queue holder ledger, expiry, refresh and release accounting; Fetcher owns cap-aware claims, not this model | `lib/wurk/queue_slot.rb` |
| Encryption | Client/server middleware envelope for the last positional argument; transforms opted-in payloads, not Client transport or Processor dispatch | `lib/wurk/encryption.rb` |
| Status | Opt-in per-job state, progress and result records with TTL/retention; not Batch completion accounting or cluster stats | `lib/wurk/status.rb`, `lib/wurk/status/` |
| Metrics | Metrics::History aggregates per-class executions through an accumulator/flusher; Query reads execution buckets, Statsd exports to a host-supplied client, Prometheus provides scrape exposition. Not History's cluster snapshots or an HTTP listener | `lib/wurk/metrics/` |
| History | Leader-gated cluster snapshots to a capped Redis stream and optional statsd client; separate from Metrics::History per-job execution aggregation | `lib/wurk/history.rb` |
| Health | Optional dedicated TCP probe listener for liveness, readiness and Prometheus metrics; no Rack/Rails dependency, separate from Web and API | `lib/wurk/health.rb` |
| Telemetry | Opt-in OpenTelemetry producer/consumer tracing across enqueue and execution; requires host-provided OTel API, not a mandatory dependency or a `Sidekiq::Telemetry` surface | `lib/wurk/telemetry.rb` |
| Sentry | Opt-in error handler and job-context middleware for host-configured Sentry; no mandatory sentry-ruby dependency and no ownership of retry policy | `lib/wurk/sentry.rb`, `lib/wurk/sentry/` |
| Logging / Profiling / Deploy markers | Logger formats context; JobLogger scopes execution logs/context; Profiler optionally captures with host-loaded Vernier; Deploy records chart markers, not deployment orchestration. Processor retains execution ownership | `lib/wurk/logger.rb`, `lib/wurk/job_logger.rb`, `lib/wurk/profiler.rb`, `lib/wurk/deploy.rb` |
| Ops commands | `wurk health`, `wurk preflight`, `wurk verify`: read-only, through a client that refuses every other command; `verify --canary` alone pushes, on request | `lib/wurk/preflight.rb`, `lib/wurk/preflight/`, `lib/wurk/cli.rb` |
| Testing | Fake in-memory, synchronous inline and real-Redis enqueue modes, with block-local overrides; test harness for Client/Worker, not a production scheduler | `lib/wurk/testing.rb` |
