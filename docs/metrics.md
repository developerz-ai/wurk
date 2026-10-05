# Metrics

Wurk records job-execution metrics into Redis on every boot, with no
configuration, and can additionally push statsd/DogStatsD metrics and periodic
cluster snapshots to an external system. There are four independent surfaces:

| # | Surface | What it gives you | Enabled by |
|---|---------|-------------------|------------|
| 1 | `Wurk::Metrics::History` server middleware | Per-class processed / failed / runtime buckets in Redis | Always (auto-registered at load) |
| 2 | `Wurk::Metrics::Query` | Ruby read API over those buckets, plus the rollup series | Always |
| 3 | `Wurk::Metrics::Statsd` server middleware | `sidekiq.*` counters, gauges, distributions to a statsd/DogStatsD client | `config.dogstatsd = …` |
| 4 | `Wurk::History` snapshotter | Periodic cluster-wide snapshot → the `history:metrics` Redis stream and/or your statsd client, with a custom-collector block | `config.retain_history(…)` |

Every one of these is exposed under its `Sidekiq::*` name too —
`Sidekiq::Metrics::Middleware`, `Sidekiq::Metrics::Query`,
`Sidekiq::Middleware::Server::Statsd`, `Sidekiq::History`, `Sidekiq::Deploy` —
so an existing Sidekiq or Sidekiq Pro/Ent initializer keeps working on the
one-line gem swap.

> **Scope.** This page covers what Wurk records, how to read it, and how to
> export it. The internal rollup buckets that back the dashboard's throughput
> and failures charts are documented separately in
> [Metrics history](metrics-history.md) — retention math, self-healing, and the
> `jr|…` key layout live there and are not repeated here.

---

## 1. Job-execution metrics (always on)

`Wurk::Metrics::History` is a server middleware added to the default chain when
`wurk` is required, so a stock boot already records metrics. It times every job
and accumulates the result in memory; a timer flushes the accumulator into the
same keys Sidekiq 8.1's `ExecutionTracker` writes (see
[Write cadence](#write-cadence-and-what-a-hard-kill-costs)):

| Key | Type | Fields | TTL |
|-----|------|--------|-----|
| `j\|<YYMMDD>\|<H>:<MM>` (minute, e.g. `j\|261004\|9:05`) | HASH | `<klass>\|p`, `<klass>\|f`, `<klass>\|ms` | 8 hours (`SHORT_TERM`) |
| `j\|<YYMMDD>\|<H>:<M>` (10 minutes: the minute's tens digit, e.g. `j\|261004\|9:0`) | HASH | same fields | 3 days (`MID_TERM`) |
| `h\|<klass>-<D>-<H>:<M>` | BITFIELD | 26 `u16` runtime-histogram counters | 8 hours |

- `p` counts **every** execution, failures included; `f` counts the ones that
  raised; `ms` is the total wall-clock milliseconds of the executions that did
  **not** fail, and only those land in the histogram. A failed job's runtime is
  noise, so average runtime is `ms / (p - f)`.
- ActiveJob payloads are recorded under the wrapped class (`job["wrapped"]`),
  not `Sidekiq::ActiveJob::Wrapper`, as upstream.
- Timestamps are UTC. The TTL is re-set on every write, so a class that keeps
  running keeps its buckets for 8 hours / 3 days measured from the *last* write.
- The key format is Sidekiq 8.1's, so metrics written by Sidekiq before the swap
  keep resolving afterwards, and Sidekiq's own Web UI reads what Wurk writes.
  The minute key always has a two-digit minute and the 10-minute key a single
  digit, so the two never collide.
- Older Wurk releases wrote `j|<YYYYMMDD>|<H>:<M>` and a per-class hourly
  `<klass>-<YYYYMMDD>-<H>` hash. Neither is written or read any more; leftover
  keys age out on their 3-day TTL, and the dashboard's per-class history starts
  fresh from the upgrade.
- Writes are best-effort: a Redis failure during the metrics write is passed to
  your error handler and never changes the job's outcome.
- An **interrupted** run — an `IterableJob` cut by `Wurk::Shutdown` or a
  quiet/rolling restart mid-iteration — books `p` and `ms`, never `f`. It is
  not a failure: the job is resumed from its saved cursor, not retried, so
  counting it as one would misreport a clean interruption as broken code. A
  run that is later resumed and completes books a second `p`/`ms` on top of
  the first — one logical job spanning an interruption produces two
  increments, matching upstream Sidekiq's own `ExecutionTracker#track`
  behavior on the same `JobRetry::Skip` case. See
  [`docs/idea/parity-divergences.md`](idea/parity-divergences.md#an-interrupted-iterablejob-run-books-p--ms-never-f-394-resolved-in-pr1)
  for the full parity determination. The Statsd emitter (below) agrees:
  `jobs.success` and the duration gauges, never `jobs.failure`.

### Write cadence and what a hard kill costs

Wurk does **not** write to Redis per job. Each worker process accumulates
`processed` / `failed` / `ms` in memory, keyed by job class and by the minute
bucket the job ran in, and flushes the whole accumulator every **≤5 seconds** in
one pipeline per Redis pool — the same `HINCRBY` / `EXPIRE` commands against the
same keys and fields, up to ten per (class, minute) inside that pool's
pipeline: `HINCRBY` of `p`, `f` (only when something failed) and `ms` (only when
something succeeded) plus an `EXPIRE` on each of the two `j|` buckets, then a
`BITFIELD` and an `EXPIRE` on the histogram — eight in the common all-success
case. `HINCRBY` is additive, so a flushed batch of N executions leaves Redis
in byte-identical state to N individual writes. It also flushes on a graceful
stop.

Writing per execution cost six Redis commands — six of the ten Wurk spent on a
job ([Benchmarks](benchmarks.md#why-wurk-is-still-behind-on-noop)) — for
counters that back a chart. Two things follow from batching them, and both are
worth knowing before you build on these numbers:

- **Counters lag by up to the flush interval.** A job that ran at `T` appears in
  the dashboard at `T + ≤5s`. Bucket *attribution* does not drift — the minute
  bucket is decided when the job runs, not when the flush happens, so a job that
  ran at 12:03:59 and flushed at 12:04:02 still counts toward 12:03.
- **A hard kill drops the unflushed window.** `SIGKILL`, an OOM kill, or a lost
  instance loses up to 5 seconds of that process's counters. Nothing about the
  *jobs* is lost — they ran, and their retry, dead-set, and private-list state is
  in Redis as always ([Reliability](reliability.md)). What is lost is statistics.
  A graceful shutdown loses nothing.

This is the trade stock Sidekiq already makes — it flushes process stats on its
10-second heartbeat and writes nothing per job — and these counters were already
explicitly best-effort (a Redis failure during a metrics write has always been
swallowed into your error handler). For anything that must reconcile exactly,
they were never the right source; use your own job-level bookkeeping.

The key layout itself has no divergence from Sidekiq 8.1: two-digit year, the
10-minute bucket included, the histogram included.

---

## 2. Reading metrics back — `Wurk::Metrics::Query`

`Wurk::Metrics::Query` (alias `Sidekiq::Metrics::Query`) has two faces.

**The instance API is Sidekiq's** (`docs/target/sidekiq-free.md` §20), so code
written against `Sidekiq::Metrics::Query` runs unchanged:

```ruby
q = Wurk::Metrics::Query.new(now: Time.now)   # pool: is optional
result = q.top_jobs(minutes: 60)              # or class_filter: /Billing/, hours: 24
result.job_results["FooJob"].totals           # {"p" => 1200, "f" => 3, "ms" => 48_000, "s" => 48.0}

job = q.for_job("FooJob", hours: 24).job_results["FooJob"]
job.series["p"]          # {"2026-10-04T09:00:00Z" => 12, …}, keyed by bucket start
job.hist                 # per-minute runtime histogram (minutes: windows only)
job.total_avg("ms")      # ms per successful execution
q.for_job("FooJob").marks  # [MarkResult(time, label, bucket)] — today's deploy marks in the window
```

`top_jobs` / `for_job` return a `Result` (`granularity`, `starts_at`, `ends_at`,
`job_results`, `marks`) whose `job_results[klass]` is a `JobResult` (`series`,
`hist`, `totals`). `minutes:` windows read the per-minute buckets; `hours:`
windows read the 10-minute buckets. Like upstream, an oversized window clamps
silently: more than 480 minutes falls back to 60, more than 72 hours to 72.

**The class-level functions back Wurk's dashboard JSON API**: flat rows,
gap-filled with zeros, and `WindowTooWide` instead of a silent clamp:

```ruby
# Top job classes by volume over the last hour.
# → [["FooJob", {p: 1200, f: 3, ms: 48_000}], ["BarJob", {…}], …]
Wurk::Metrics::Query.top_jobs(minutes: 60)
Wurk::Metrics::Query.top_jobs(minutes: 60, class_filter: "Billing")

# Per-class time-series, oldest→newest. Pass exactly one of minutes:/hours:.
# minutes: gives one row per minute, hours: one per 10-minute bucket.
# → [{at: <Time>, p: 12, f: 0, ms: 430}, …]
Wurk::Metrics::Query.for_job("FooJob", minutes: 60)
Wurk::Metrics::Query.for_job("FooJob", hours: 24)

# Cluster totals from the rollup buckets (see docs/metrics-history.md).
# bucket is "1m" | "5m" | "1h"; window is seconds, clamped to the bucket TTL.
# → [{at: <epoch int>, p:, f:, ms:}, …] gap-filled with zeros
Wurk::Metrics::Query.history("1m", 3600)

# Per-queue depth + head-of-line latency gauges.
# → [{name: "default", points: [{at:, size:, latency:}, …]}, …]
Wurk::Metrics::Query.queue_history("5m", 86_400)
Wurk::Metrics::Query.queue_history("5m", 86_400, queues: %w[default critical])
```

Window caps (`WindowTooWide < ArgumentError` when exceeded):

| Call | Cap | Reads |
|------|-----|-------|
| `top_jobs(minutes:)` | `MAX_MINUTES` = 480 (8h), matching the per-minute bucket retention | per-minute `j\|…` buckets |
| `top_jobs(hours:)` | `MAX_HOURS` = 72 (3d), matching the 10-minute bucket retention | 10-minute `j\|…` buckets |
| `for_job(minutes:)` | 480 | per-minute buckets |
| `for_job(hours:)` | 72 (3d) | 10-minute buckets |
| `history` / `queue_history` | window clamped to the bucket's TTL (24h / 7d / 30d) | `jr\|…` / `qm\|…` |

A wider window has no data to read anyway — the source buckets are TTL'd out —
so `top_jobs` and `for_job` raise rather than return silently sparse results.
`history` and `queue_history` clamp instead of raising; an unknown bucket name
or a non-positive window raises `ArgumentError`. `queue_history` returns at
most `MAX_QUEUE_SERIES` (25) queues, taken in sorted order, to bound the
payload.

### Rollups and queue gauges

Two leader-gated background threads run in every worker process (only the
elected leader writes):

- `Wurk::Metrics::Rollup` — sums the per-class minute buckets into cluster-total
  `jr|1m|…` / `jr|5m|…` / `jr|1h|…` hashes. Retention, self-healing, and Redis
  footprint: [Metrics history](metrics-history.md).
- `Wurk::Metrics::QueueRollup` — samples each queue's `LLEN` and head-of-line
  latency into `qm|1m|…` / `qm|5m|…` / `qm|1h|…` hashes with fields
  `<queue>|sz` and `<queue>|lt`. Same three resolutions and the same
  24h / 7d / 30d TTLs. These are **gauges**, so within a coarse bucket each
  minute's sample overwrites the previous one — the bucket holds the last value
  in its window, not a sum.

Both tick every 60 seconds by default; override with
`config[:metrics_rollup_interval]` (seconds — mainly a test hook).

---

## 3. Statsd / DogStatsD

`Wurk::Metrics::Statsd` is a server middleware that is **already in the default
chain**. It costs nothing until you give it a client: with no client configured
it yields straight through. To turn it on, hand Wurk a callable that builds the
client:

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.dogstatsd = -> { Datadog::Statsd.new("metrics.example.com", 8125) }
end
```

- The value is a **callable**, invoked once per process and memoized, so the
  client is built *after* fork. (A bare client object is accepted too, but a
  lambda is correct: `Datadog::Statsd` keeps thread-locals that must be
  initialized inside the child.)
- `Sidekiq::Pro.dogstatsd = …` is accepted as an alias and sets the same value.
- Any object responding to `increment` / `gauge` / `distribution` works.
  Clients without `distribution` (vanilla `statsd-ruby`) fall back to
  `histogram`; clients with neither silently drop distribution metrics.
- The middleware is already registered, so the Sidekiq Pro snippet
  `require "sidekiq/middleware/server/statsd"; chain.add
  Sidekiq::Middleware::Server::Statsd` is accepted but unnecessary.
- Emission is best-effort everywhere: a raise inside the client is routed to
  your error handler, never into the job result.

### Metrics emitted

Every name carries the hardcoded `sidekiq.` prefix (not configurable — so
third-party dashboards built for Sidekiq Pro work unchanged).

| Metric | Type | Tags | Emitted when |
|--------|------|------|--------------|
| `sidekiq.jobs.count` | counter | `worker:<class>`, `queue:<q>` | job starts (server middleware) |
| `sidekiq.jobs.success` | counter | `worker:`, `queue:` | job returned |
| `sidekiq.jobs.failure` | counter | `worker:`, `queue:` | job raised |
| `sidekiq.jobs.perform` | gauge | `worker:`, `queue:` | job finished — duration in ms |
| `sidekiq.jobs.perform_dist` | distribution | `worker:`, `queue:` | job finished — duration in ms |
| `sidekiq.jobs.enqueued` | counter | `worker:`, `queue:` | client push, after middleware and Redis both succeed |
| `sidekiq.jobs.retried` | counter | `worker:`, `queue:` | a retry is scheduled |
| `sidekiq.jobs.expired` | counter | `class:<class>` | expiry middleware drops a stale job |
| `sidekiq.jobs.rate_limited` | counter | `worker:<class>` | limiter reschedules an over-limit job |
| `sidekiq.jobs.encryption_error` | counter | `worker:<class>` | a payload fails to decrypt and is sent to dead |
| `sidekiq.jobs.poison` | counter | `class:`, `queue:` | poison-pill detector kills a repeatedly-crashing job |
| `sidekiq.jobs.recovered.fetch` | counter | `class:`, `queue:` | a job is recovered from a dead process's private list |
| `sidekiq.jobs.recovered.push` | counter | — | the buffered client replays a push after a Redis outage |
| `sidekiq.jobs.dropped.push` | counter | — | the buffered client drops a job because the outage buffer overflowed (`:drop_oldest`); one ERROR log per drop burst |
| `sidekiq.batch.created` | counter | — | a batch's first flush |
| `sidekiq.batch.duration_dist` | distribution | — | batch success — seconds from creation |
| `sidekiq.busy` | gauge | `process:<identity>` | every heartbeat — this process's in-flight jobs |
| `sidekiq.queue.size` | gauge | `queue:<q>`, `process:<identity>` | every heartbeat — per-queue `LLEN` |

Notes:

- `sidekiq.queue.size` and `sidekiq.busy` are emitted by **every** process, tagged
  with `process:`. Aggregate with `max` (not `sum`) across the process tag for
  `queue.size`, or you multiply the depth by your process count. `busy` is
  per-process and sums correctly.
- Tag key naming is inconsistent by design — it follows each call site's
  history. `worker:` on the job-lifecycle metrics, `class:` on `jobs.expired`,
  `jobs.poison`, and `jobs.recovered.fetch`.
- The heartbeat gauges skip their Redis pipeline entirely when no client is
  configured.

### Per-job tags and sample rate

Set a callable on the middleware class to override tags or sample rate per job.
It receives `(klass, job, queue)` and returns a hash; a non-hash return is
ignored:

```ruby
# config/initializers/wurk.rb
Wurk::Metrics::Statsd.options = lambda do |klass, job, queue|
  { tags: ["worker:#{klass}", "queue:#{queue}", "tenant:#{job['tenant']}"],
    sample_rate: klass == "HighVolumeJob" ? 0.1 : 1.0 }
end
```

Defaults are tags `["worker:<class>", "queue:<queue>"]` and sample rate `1.0`
(no `sample_rate` keyword is passed to the client at 1.0). A `dd_rate` field on
the job payload always wins over both the default and your block, so you can
sample a single push:

```ruby
FooJob.set(dd_rate: 0.05).perform_async(1)
```

### Emitting your own metrics through the same client

The class-level helpers are the same ones Wurk uses internally. They prefix
`sidekiq.` and no-op when no client is configured, so you never have to guard:

```ruby
Wurk::Metrics::Statsd.increment("orders.settled", tags: ["region:eu"])
Wurk::Metrics::Statsd.gauge("orders.backlog", 42)
Wurk::Metrics::Statsd.distribution("orders.settle_ms", 128.4, sample_rate: 0.5)
```

`Wurk::Metrics::Statsd.reset!` drops the memoized client — needed only in tests
and after a fork that inherited one.

---

## 4. Custom historical metrics — `Wurk::History`

`config.retain_history` starts a leader-gated snapshotter thread that runs
every N seconds. Each tick it appends a snapshot to the capped Redis stream
`history:metrics` **and**, if a statsd client is configured, emits the same
values to it. Nothing runs unless you call `retain_history`.

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.dogstatsd = -> { Datadog::Statsd.new("localhost", 8125) }
  config.retain_history(30)          # seconds; default 30
end
```

The default snapshot (the §5.2 gauge set) is:

| Stream field | Statsd gauge | Source |
|--------------|--------------|--------|
| `processed` | `sidekiq.processed` | `Wurk::Stats#processed` |
| `failures` | `sidekiq.failures` | `Wurk::Stats#failed` |
| `enqueued` | `sidekiq.enqueued` | total queue size |
| `retries` | `sidekiq.retries` | retry set size |
| `dead` | `sidekiq.dead` | dead set size |
| `scheduled` | `sidekiq.scheduled` | scheduled set size |
| `busy` | `sidekiq.busy` | active job count |

These gauges are untagged and cluster-wide — distinct from the per-process
`sidekiq.busy` the heartbeat emits.

### Custom collector block

Pass a block to replace the default statsd emission entirely. The block
receives the raw client, which quacks like `Datadog::Statsd`
(`gauge` / `count` / `histogram` / `batch`), and writes **fully-qualified**
metric names itself — the `sidekiq.` prefix is not added for you here:

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.dogstatsd = -> { Datadog::Statsd.new("localhost", 8125) }

  config.retain_history(30) do |s|
    Sidekiq::Queue.all.each do |q|
      s.batch do |b|
        b.gauge("sidekiq.queue.latency", q.latency, tags: ["queue:#{q.name}"])
        b.gauge("sidekiq.queue.size",    q.size,    tags: ["queue:#{q.name}"])
      end
    end
    s.gauge("app.orders.pending", Order.pending.count)
  end
end
```

- `retain_history(seconds)` raises `ArgumentError` for a non-positive interval.
- The block replaces only the **statsd** side. The default field set is still
  written to the `history:metrics` stream every tick, so the dashboard's
  Historical panel keeps working whether or not you have a statsd client.
- **Divergence from Ent:** Sidekiq Enterprise has no built-in store and offloads
  persistence entirely to your TSDB. Wurk always writes the stream, so the
  snapshotter is useful with no external statsd at all — configure
  `retain_history` and leave `dogstatsd` unset.
- Leader-gated via the cluster `dear-leader` lock, so exactly one process in the
  cluster emits per interval.

### Reading snapshots back

```ruby
Wurk::History.recent(limit: 500)
# → [{at: 1780000000.0, processed: 812, failures: 3, enqueued: 12, …}, …]
```

Oldest→newest. `at` is epoch seconds derived from the Redis stream ID. Fields
are read generically and coerced to Int/Float where possible (non-numeric
values pass through untouched), so a stream written by a migrated Sidekiq
Enterprise install renders without rewriting. `limit` is clamped to
`1..STREAM_CAP`; the default is `STREAM_DEFAULT_LIMIT` (1000).

The stream is capped with `XADD MAXLEN ~ 10_000` (`STREAM_CAP`). At the default
30-second interval that is roughly 3.5 days of history. `~` lets Redis trim in
whole macro-nodes, so the live length can briefly exceed the cap. Override with
`config[:history_stream_cap]`.

`Wurk::History#snapshot` takes one snapshot immediately, bypassing both the
leader gate and the sleep loop — useful in tests or a manual "snapshot now".

---

## 5. Dashboard views and JSON API

The **Metrics** page in the dashboard reads only the surfaces above. Its
range selector (`1h` / `24h` / `7d` / `30d`) picks the rollup bucket:

| Panel | Source |
|-------|--------|
| Throughput & failures area chart | `GET /api/history/:bucket?window=` → `jr\|…` rollups |
| Queue depth bars | `GET /api/queue-history/:bucket?window=` → `qm\|…` gauges |
| Queue latency lines | same endpoint, `latency` field |
| Top job types table | `GET /api/metrics?minutes=&substr=` → `Query.top_jobs` |
| Per-class modal (click a row) | `GET /api/metrics/:klass?minutes=` / `?hours=` → `Query.for_job` |
| Historical snapshots | `GET /api/history/snapshots?limit=` → `Wurk::History.recent` |

The Dashboard page reuses `GET /api/history/:bucket` for its own throughput
chart. All paths are relative to your engine mount (`/wurk/api/…` for a
`mount Wurk::Engine => "/wurk"`), and all of them are gated by the controls in
[Authentication & authorization](authentication.md).

| Endpoint | Parameters |
|----------|------------|
| `GET /api/metrics` | `minutes` (1–480, default 60), `substr` prefix filter on class name |
| `GET /api/metrics/:klass` | `minutes` (1–480, default 60) **or** `hours` (1–72, default 24) |
| `GET /api/history/:bucket` | `:bucket` and `window` — contract and response shape in [Metrics history § API](metrics-history.md#api) |
| `GET /api/queue-history/:bucket` | same, plus `queue=<name>` to narrow to one queue |
| `GET /api/history/snapshots` | `limit` (1–10000, default 1000) |

An unknown bucket, a non-positive window, or a too-wide `minutes`/`hours`
returns `400` with `{"error": "…"}`. Series responses use the wire names
`processed` / `failed` / `runtime_ms` for the internal `p` / `f` / `ms` fields.

### Deploy marks

`Wurk::Deploy.mark!` records deploy markers wire-compatibly with
`Sidekiq::Deploy`:

```ruby
Wurk::Deploy.mark!                        # label defaults to `git log -1 --format="%h %s"`
Wurk::Deploy.mark!("v2.4.0 rollout")      # positional, as capistrano-sidekiq calls it
Wurk::Deploy.new.fetch(Date.today)        # → {"2026-07-20T10:31:00Z" => "abc123 fix"}
```

Marks land in `<YYYYMMDD>-marks` (HASH, TTL 90 days), deduped per label by a
60-second `deploylock-<label>` lock so a fleet-wide deploy writes one row rather
than one per process. The instance `Query` results carry them in `marks`, as
upstream; the dashboard does not draw them yet. Read them directly with
`Deploy#fetch`.

---

## 6. Redis footprint and retention

Everything on this page is bounded by TTL or by a stream cap; nothing grows
without limit.

| Key | Written by | Retention | Steady-state size |
|-----|-----------|-----------|-------------------|
| `j\|<YYMMDD>\|<H>:<MM>` | every worker, ≤5s | 8 hours from last write | ≤ 480 keys; 3 fields × active job classes each |
| `j\|<YYMMDD>\|<H>:<M>` | every worker, ≤5s | 3 days from last write | ≤ 432 keys; 3 fields × active job classes each |
| `h\|<klass>-<D>-<H>:<M>` | every worker, ≤5s | 8 hours from last write | ≤ 480 keys × active job classes; 52 bytes each |
| `jr\|{1m,5m,1h}\|<epoch>` | rollup leader | 24h / 7d / 30d | ≈ 4 176 keys total — see [Metrics history](metrics-history.md) |
| `qm\|{1m,5m,1h}\|<epoch>` | queue-rollup leader | 24h / 7d / 30d | ≈ 4 176 keys; 2 fields × live queues each |
| `history:metrics` | `retain_history` snapshotter | capped at ~10 000 entries | ~3.5 days at the 30s default |
| `<YYYYMMDD>-marks` | `Deploy.mark!` | 90 days | one small HASH per day |

The per-class keys are the only ones that scale with job-class cardinality —
an app that generates dynamic class names (thousands of distinct `class`
values) pays for it in the minute, 10-minute and histogram keys. Everything else is
bounded by time and queue count. Empty rollup buckets are skipped, so an idle
cluster writes nothing.

---

## 7. Exporting to an external system

Three supported export paths:

**Prometheus (pull, built in).** Enable the health listener
(`config.health_check(port: 7433)`) and scrape `GET /metrics` (text format
0.0.4); pass `metrics: false` to `health_check` to turn it off. Families:
`wurk_build_info`, `wurk_redis_up`, `wurk_processed_total`, `wurk_failed_total`,
`wurk_queue_size{queue}`, `wurk_queue_latency_seconds{queue}`,
`wurk_scheduled_size`, `wurk_retry_size`, `wurk_dead_size`, `wurk_processes`,
`wurk_busy`, `wurk_concurrency`, `wurk_swarm_children_expected`,
`wurk_swarm_children_fresh`, and per process (`{pid}`) `wurk_process_busy`,
`wurk_process_concurrency`, `wurk_process_rss_bytes`,
`wurk_process_heartbeat_age_seconds`, `wurk_process_quiet`. Cluster families
come from shared Redis and are identical on every pod — aggregate with `max`,
not `sum`; `wurk_process_*` and `wurk_swarm_children_*` describe the scraped
pod's own swarm. Values are cached for 1s and one scrape costs one Redis
checkout; `wurk_redis_up 0` means the last refresh could not read Redis. No new
Redis keys.

**Statsd / DogStatsD (push).** Set `config.dogstatsd` to anything responding to
`increment` / `gauge` / `distribution` and the metrics in §3 flow to it
continuously. With a Datadog Agent (or a statsd-to-Prometheus bridge such as
`statsd_exporter`) listening on the UDP port, this is the whole integration —
Wurk's side is the one-line client assignment. Use `config.retain_history` on
top of it for the cluster-wide gauges in §4, and a custom collector block for
anything else you want sampled on a fixed interval.

**Query API (pull, custom).** For per-class series the built-in exporter doesn't carry, expose your own endpoint
in your app and build the response from `Wurk::Metrics::Query` and
`Wurk::Stats`:

```ruby
# app/controllers/internal/wurk_metrics_controller.rb
class Internal::WurkMetricsController < ApplicationController
  def show
    lines = Wurk::Metrics::Query.top_jobs(minutes: 5).flat_map do |klass, t|
      [%(wurk_jobs_processed{class="#{klass}"} #{t[:p]}),
       %(wurk_jobs_failed{class="#{klass}"} #{t[:f]})]
    end
    render plain: "#{lines.join("\n")}\n", content_type: "text/plain"
  end
end
```

Mind the window caps (§2) and remember these are windowed sums, not
monotonic counters — pick a window matched to your scrape interval, or scrape
`Wurk::Stats#processed` / `#failed` for the lifetime totals a Prometheus
counter expects. Gate the endpoint yourself; it is your controller, not the
engine's.

For long-term retention beyond 30 days, the external system is the answer in
both directions — Wurk's own buckets expire and are not designed as a TSDB.

---

## Related

- [Metrics history](metrics-history.md) — the `jr|…` rollup buckets, retention
  math, and self-healing behind the throughput charts.
- [Dashboard](dashboard.md) — mounting, configuring, and extending the UI.
- [Authentication & authorization](authentication.md) — gating the JSON API
  these views read.
