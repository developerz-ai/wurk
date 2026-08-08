# 00 — Cross-ecosystem census

> Part of [`overview.md`](overview.md). Depends on: none. **Reference only — no code changes.**

Surveyed 2026-08-07: BullMQ + Pro, pg-boss, Bee-Queue · Oban + Pro · River, Asynq, Faktory, Machinery · Celery, Dramatiq, RQ, arq, Huey · Laravel Queues + Horizon, Symfony Messenger · Hangfire, Quartz.NET · JobRunr · Temporal, Restate, Inngest, Trigger.dev, Hatchet · Solid Queue, GoodJob, Que, Resque · SQS, Cloud Tasks, Cloudflare Queues, Azure Service Bus.

Legend: ✅ shipped · 🟡 partial · ❌ absent.

## Where Wurk already leads

Batches + callbacks, five limiter types, leader-elected cron, unique jobs, AES-256-GCM encryption + rotation, transactional enqueue (`transaction_aware_client.rb`), outage buffering (`client/buffered.rb`), reliable BLMOVE fetch, Lua bulk enqueue, metrics + history + StatsD, queue pause, poison-pill guard, fork parallelism, K8s probes. Ahead of every surveyed system except the durable-execution tier.

## Gaps, by area

### Orchestration
| Capability | Prior art | Wurk | Slice |
|---|---|---|---|
| Batch + completion callback | Sidekiq Pro, Hangfire, Faktory | ✅ | — |
| DAG / parent-child flows | BullMQ `FlowProducer`, Oban Pro Workflows, Celery `chord`, Temporal child workflows | ❌ | 11 |
| Chains (ordered, result piped) | Laravel `Bus::chain`, Celery `chain`, Oban Pro chains | ❌ | 11 (follow-on) |
| Continuations | Hangfire `ContinueJobWith` | 🟡 one-job batch | 11 |
| Saga / compensation | Temporal, Restate | ❌ | non-goal |
| Durable replayable steps | Temporal, Inngest, Trigger.dev | ❌ | non-goal |

### Dedup
| Capability | Prior art | Wurk | Slice |
|---|---|---|---|
| until_executed / executing / both | Sidekiq Ent, Asynq, River | ✅ `Wurk::Unique` | — |
| Unique by arg subset | River, Laravel `uniqueId` | 🟡 whole-arg hash | 09 |
| Debounce (collapse burst, keep last) | pg-boss debounce, Inngest, BullMQ dedup TTL-extend | ❌ | 09 |
| Throttle-to-slot (one per N sec) | pg-boss `singletonSeconds` | ❌ | 09 |

### Concurrency & rate
| Capability | Prior art | Wurk | Slice |
|---|---|---|---|
| Concurrent/window/bucket/leaky/points | Sidekiq Ent | ✅ | — |
| Global per-queue concurrency | BullMQ global concurrency, Oban Pro Smart Engine | ❌ | 10 |
| Keyed groups (tenant = concurrency+rate+priority+pause) | BullMQ Pro Groups, Hatchet | ❌ | deferred |
| Sequential partitions in a concurrent queue | Oban Pro chains | ❌ | deferred |
| Dynamic rate limit (worker signals back-off) | BullMQ `RateLimitError` | ❌ | deferred |

### Reliability
| Capability | Prior art | Wurk | Slice |
|---|---|---|---|
| Reliable fetch, crash reclaim | Sidekiq Pro, Faktory | ✅ | — |
| Per-job timeout | Asynq, Celery `time_limit`, Dramatiq | ❌ | 08 |
| Per-job deadline | Asynq `Deadline`, Cloud Tasks | 🟡 `expires_in` pre-execution only (`middleware/expiry.rb`) | 08 |
| Lease renewal / stall watchdog | SQS visibility timeout, BullMQ stalled checker, River | 🟡 reclaimed at process boot only | deferred |
| Filtered DLQ redrive | SQS redrive, pg-boss | 🟡 retry-all, no filter | deferred |

### State & observability
| Capability | Prior art | Wurk | Slice |
|---|---|---|---|
| Store return value | BullMQ `returnvalue`, Celery result backend, Oban Pro output | ❌ | 06 |
| Retain completed jobs | Asynq retention, Hangfire succeeded list | ❌ | 06 |
| Look up state by jid | sidekiq-status, BullMQ `Job.fromId` | 🟡 dashboard set scan | 06 |
| Per-job progress | BullMQ `updateProgress`, sidekiq-status | 🟡 batches + iterables only | 06 |
| OpenTelemetry traces | BullMQ 5.x, Temporal, JobRunr | ❌ | 05 |
| Prometheus endpoint | AsynqMon, Hangfire exporters | ❌ | deferred |
| Outbound webhooks / event stream | Inngest, Trigger.dev, Hatchet | 🟡 SSE for SPA only | deferred |
| Cooperative cancellation | Celery `revoke`, BullMQ observables, Temporal | ❌ | deferred |

### Polyglot & remote
| Capability | Prior art | Wurk | Slice |
|---|---|---|---|
| Language-agnostic producers | Faktory (7+ client langs), BullMQ (Python/Rust/Elixir/PHP/.NET) | ❌ | 07 |
| HTTP enqueue | Cloud Tasks, Cloudflare Queues, Inngest | ❌ | 07 |
| Versioned admin API | SQS API, Hangfire | 🟡 dashboard JSON only | 07 |
| HTTP consumer protocol (fetch/ack) | Faktory, Cloud Tasks push targets | ❌ | non-goal (see 07 §non-goals) |

### Priority
Per-job numeric priority inside one queue (BullMQ, Dramatiq, pg-boss, Solid Queue, River) is **deferred, not dropped**: Sidekiq queues are Redis **lists**, so it needs a parallel zset — which skews ordering against non-Wurk producers on the same queue and violates pillar 1. Ship only with a design that degrades cleanly, or not at all.

## Declared non-goals

- **Durable-execution engine** (Temporal/Restate replay + determinism + workflow versioning). Different failure model; not expressible in Sidekiq job JSON. Flows (slice 11) cover the 80% Rails apps reach for.
- **SQL backend** (River/Oban/Solid Queue/pg-boss/Hangfire territory). Pillar 1 is "same Redis key schema"; a second backend halves parity confidence and competes for a user Wurk isn't targeting.
- **Anything mutating an existing key or JSON field.**

## Sources

BullMQ [docs](https://docs.bullmq.io/) · [flows](https://docs.bullmq.io/guide/flows) · [Pro changelog](https://docs.bullmq.io/bullmq-pro/changelog) — Oban Pro [site](https://oban.pro/) · [releases](https://oban.pro/releases/pro) — River [site](https://riverqueue.com/) · [repo](https://github.com/riverqueue/river) — Asynq [repo](https://github.com/hibiken/asynq) · [aggregation](https://github.com/hibiken/asynq/wiki/Task-aggregation) · [unique](https://github.com/hibiken/asynq/wiki/Unique-Tasks) — Faktory [wiki](https://github.com/contribsys/faktory/wiki) — Celery [canvas](https://docs.celeryq.dev/en/stable/userguide/canvas.html) · [time limits](https://deepwiki.com/celery/celery/3.5-time-limits-and-rate-limits) — Dramatiq [guide](https://dramatiq.io/guide.html) — pg-boss [site](https://pgboss.io/) · [jobs API](https://timgit.github.io/pg-boss/api/jobs) — Laravel [queues](https://laravel.com/docs/12.x/queues) — Hangfire [overview](https://www.hangfire.io/overview.html) — Temporal [workflow execution](https://docs.temporal.io/workflow-execution) — Hatchet/Trigger.dev/Inngest [comparison](https://www.pkgpulse.com/guides/hatchet-vs-trigger-dev-v3-vs-inngest-durable-workflows-2026) — Solid Queue [repo](https://github.com/rails/solid_queue) — GoodJob [repo](https://github.com/bensheldon/good_job) — SQS [patterns](https://jayendrapatil.com/aws-sqs-simple-queue-service/) — Cloud Tasks [docs](https://cloud.google.com/tasks/docs/migrating)
