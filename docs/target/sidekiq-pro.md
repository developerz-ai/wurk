# Sidekiq Pro Public API Surface

Reference spec for Wurk — drop-in replacement for `sidekiq-pro`. Compiled from the public Sidekiq wiki, `Pro-Changes.md`, contribsys docs, and well-known issue threads. Covers Pro 7.x / 8.x surface. Anything Enterprise-only (rate limiting, periodic jobs, encryption, leader election) is out of scope.

Loaded via `require 'sidekiq-pro'`. Web extensions via `require 'sidekiq/pro/web'`.

---

## 1. Top-level constants & module

```ruby
module Sidekiq
  module Pro
    VERSION   = "x.y.z"      # gem version string
    LICENSE   = "..."        # license text fingerprint, checked at boot

    # Statsd client accessor (set by Sidekiq.configure_server)
    def self.dogstatsd=(callable); end
    def self.dogstatsd;            end
  end
end
```

Boot-time license check raises if `SIDEKIQ_PRO_LICENSE` env var (or gem source token) is missing/invalid. Wurk should no-op this gate (open source).

---

## 2. Batches — `Sidekiq::Batch`

### 2.1 Creation

```ruby
batch = Sidekiq::Batch.new                  # new batch, fresh BID
batch = Sidekiq::Batch.new(bid_string)      # reopen existing batch (only legal from a job or callback)
```

`bid` is a URL-safe random string (~12 bytes base64).

### 2.2 Instance API

| Method | Returns | Notes |
| --- | --- | --- |
| `#bid` | String | unique batch id |
| `#description` / `#description=` | String | shown in Web UI |
| `#callback_queue` / `#callback_queue=` | String | queue used for callback jobs (default `"default"`) |
| `#callback_class` / `#callback_class=` | Class/String | optional class used to resolve string `"Klass#method"` callbacks |
| `#tags` / `#tags=` | Array<String> | searchable tags (Pro 8.1+) |
| `#autoflush` / `#autoflush=` | Integer | flush every N jobs collected inside `#jobs` block (Pro 8.x) |
| `#parent_bid` | String / nil | parent batch id if nested |
| `#parent` | `Sidekiq::Batch` / nil | parent batch object |
| `#mutable?` | Boolean | true until first flush; false from callbacks |
| `#include?(jid)` | Boolean | membership check |
| `#remove_jobs(*jids)` | Integer | drop jobs from the batch (Pro 8.x) |
| `#invalidate_all` | nil | mark batch (and all descendants) invalid; jobs short-circuit |
| `#valid?` | Boolean | inverse of invalidated |
| `#status` | `Sidekiq::Batch::Status` | snapshot |
| `#expires_in(duration)` | self | override default 30d expiry |

### 2.3 `#jobs` block — atomic enqueue

```ruby
batch.jobs do
  rows.each { |r| RowJob.perform_async(r) }
end
```

- Pushes all jobs in one Redis pipeline / transaction.
- Increments `total` and `pending` atomically with the enqueue.
- Must be called **once** at creation (or from inside a job to add siblings).
- Re-entrancy from inside a worker: `batch.jobs { ... }` is legal and grows `total`.
- Empty `#jobs` block is legal as of Pro 7.1 — synthesises a `Sidekiq::Batch::Empty` no-op job so callbacks still fire.

### 2.4 Callbacks — `#on`

```ruby
batch.on(:success,  MyCallback, "key" => v)        # class with #on_success(status, opts)
batch.on(:complete, "Klass#method", "uid" => 7)    # string spec, method named explicitly
batch.on(:death,    DeathHandler)                  # block-less form

# convention: target.on_<event>(status, options)
# if target is "Foo#bar" the method "bar" is called instead of on_<event>
```

Callback signatures:

```ruby
class MyCallback
  def on_success(status, options); end
  def on_complete(status, options); end
  def on_death(status, options);    end
end
```

Events:

| Event | When fired | Semantics |
| --- | --- | --- |
| `:success` | All jobs in batch (and all descendant batches) succeeded | Fires **once**. Never fires if any job died. |
| `:complete` | Every job executed at least once (success OR exhausted retries) | Fires once. May fire even with failures. |
| `:death` | First job in batch exhausts retries / `dead: false` and discards | Fires per-batch on the first death only. Independent of `:complete`. |

Rules:

- `options` is JSON-serialised; only basic types allowed.
- Callbacks run as ordinary Sidekiq jobs on `callback_queue`; retry on failure like any job.
- `:success` and `:death` are **not mutually exclusive** — death fires first, success never fires unless the dead job is manually retried to success.
- Child `:success` fires before parent `:success`. Child `:complete` fires before parent `:complete`. No ordering between child `:success` and parent `:complete`.
- **Wurk (#213):** `#on` after the first flush — following a `#jobs` call or on a batch reopened by bid — persists the callback to `b-<bid>` immediately (atomic server-side append), so it is never silently dropped. Registering on a batch whose Redis hash no longer exists raises `ArgumentError`; registering for an event that already fired logs a warning (the callback will never run).
- **Wurk:** every `#on` is deduped and capped, before the first flush (in memory) and after it (in the Lua append) alike. Re-registering an identical `[event, target, options]` triple is a no-op (one entry, one callback job), so reopening a batch per job to register its callback costs O(1) instead of growing the array; past 1000 entries (`Batch::CALLBACKS_MAX`) the registration is refused and logged. Options are compared as persisted, so `a: 1` and `'a' => 1` are the same callback. Distinct callbacks for the same event are unaffected — any number may be registered.

### 2.5 `Sidekiq::Batch::Status`

```ruby
status = Sidekiq::Batch::Status.new(bid)
```

| Method | Returns |
| --- | --- |
| `#bid` | String |
| `#parent_bid` | String / nil |
| `#total` | Integer (jobs added) |
| `#pending` | Integer (not yet succeeded) |
| `#failures` | Integer (currently failing) |
| `#created_at` | Float (epoch) |
| `#complete_at` | Float / nil (Pro 8.x) |
| `#success_at` | Float / nil (Pro 8.x) |
| `#death_at` | Float / nil (Pro 8.x) |
| `#complete?` | Boolean |
| `#failure_info` | Array (deprecated; pre-Pro 8) |
| `#failed_jids` | Array<String> |
| `#dead_jids` | Array<String> |
| `#child_count` | Integer |
| `#description` | String |
| `#tags` | Array<String> |
| `#data` | Hash (JSON-serializable summary, used by polling endpoint) |
| `#join` | nil; blocks current thread until `complete?` (test/util only) |
| `#delete` | nil; nukes batch keys (dangerous if jobs in flight) |
| `#invalidated?` | Boolean |

### 2.6 Worker-side helpers (mixed into `Sidekiq::Job`)

```ruby
class MyJob
  include Sidekiq::Job

  def perform(...)
    bid                       # => current batch id or nil
    batch                     # => Sidekiq::Batch or nil
    valid_within_batch?       # false if batch was invalidate_all'd
    return unless valid_within_batch?

    batch&.jobs do            # add siblings to *own* batch
      ChildJob.perform_async
    end
  end
end
```

### 2.7 Batch sets — discovery API

```ruby
Sidekiq::BatchSet.new.size
Sidekiq::BatchSet.new.each { |status| ... }            # iterates Status objects
Sidekiq::BatchSet.new.scan_tags("customer:1234") do |bid|
  Sidekiq::Batch::Status.new(bid)
end

Sidekiq::Batch::DeadSet.new.each do |status|
  status.dead_jids.each { |jid| ... }
end
```

### 2.8 Redis data model for batches

Key prefix: `b-<bid>`. Default expiries: hash 30d while pending, 24h post-success.

| Key | Type | Purpose |
| --- | --- | --- |
| `b-<bid>` | hash | core fields: `created_at`, `total`, `pending`, `failures`, `description`, `parent_bid`, `callback_queue`, `callback_class`, `tags`, `complete`, `success`, `death`, `complete_at`, `success_at`, `death_at` |
| `b-<bid>-jids` | set | live JIDs in the batch |
| `b-<bid>-failinfo` | hash | jid → error JSON (pre-Pro 8) |
| `b-<bid>-failed` | set | failed JIDs (Pro 8+) |
| `b-<bid>-died` | set | JIDs that died (drove `:death`) |
| `b-<bid>-success` | string/marker | `:success` callbacks pending |
| `b-<bid>-complete` | string/marker | `:complete` callbacks pending |
| `b-<bid>-notify` | set | callbacks queued (30d ttl) |
| `b-<bid>-cbsucc` | set | success callback dedup marker (30d ttl) |
| `b-<bid>-kids` | set | child batch BIDs |
| `b-<bid>-pkids` | set | pending child BIDs (not yet succeeded) |
| `b-<bid>-tags` | set | applied tags |
| `BID` | string | global counter (legacy) |
| `batches` | sorted set | discovery index; score = created_at |
| `dead-batches` | sorted set | batches that hit `:death` |
| `tags:<tag>` | set | reverse index for `scan_tags` |

All operations are implemented as Lua scripts for atomicity: `EVALSHA` against pre-loaded scripts named e.g. `batch_push.lua`, `batch_complete.lua`, `batch_invalidate.lua`.

### 2.9 Complex / nested workflows

```ruby
overall = Sidekiq::Batch.new
overall.on(:success, "FulfillmentCallbacks#shipped", "oid" => order.id)
overall.jobs do
  StartWorkflow.perform_async(order.id)
end

# inside a callback that runs after step1:
def step1_done(status, options)
  parent = Sidekiq::Batch.new(status.parent_bid)
  parent.jobs do
    step2 = Sidekiq::Batch.new
    step2.on(:success, "FulfillmentCallbacks#step2_done", "oid" => options["oid"])
    step2.jobs do
      B.perform_async
      C.perform_async
    end
  end
end
```

Rules of nesting:

- A job opens **its own** batch only (`batch.jobs { ... }`).
- A callback opens its **parent** batch only (via `status.parent_bid`).
- Callbacks cannot mutate the batch they belong to — the batch is already terminal.
- Child success cascades into parent pending-count decrement, so parent `:success` waits on full subtree.

---

## 3. Reliability — server fetch (`super_fetch`)

### 3.1 Activation

```ruby
Sidekiq.configure_server do |config|
  config.super_fetch!
end
```

Optional recovery callback:

```ruby
Sidekiq.configure_server do |config|
  config.super_fetch! do |jobstr, pill|
    Rails.logger.warn "recovered: #{jobstr}"
    Rails.logger.warn "poison: #{pill.jid} #{pill.klass}" if pill
  end
end
```

### 3.2 Algorithm

- On boot, process registers a **private queue** per public queue it consumes. Naming: `queue:<public>|<hostname>|<pid>|<index>` (pipe separators; underscores caused parsing bugs historically).
- Fetch loop uses Redis `LMOVE public_queue private_queue RIGHT LEFT` (formerly `RPOPLPUSH`/`BRPOPLPUSH`) — atomic move from public list tail to private list head.
- Job remains in the private queue until the worker explicitly `LREM`s it after success or retry handling.
- Process death: heartbeat key `processes` expires after 60s. Orphan sweeper (1/min within process group, full SCAN 1/hr) finds private queues for dead processes and `RPOPLPUSH`es items back to their public queue.
- **Poison pill**: an orphan recovered ≥ 3 times within 72h is killed → pushed to dead set + Statsd `jobs.poison`. Callback receives `pill` object: `{ jid:, klass:, count:, queue: }`.

### 3.3 Polling vs blocking

`super_fetch` polls each public queue (does not `BRPOP`), because `LMOVE` has no blocking pair across multiple lists. Tradeoff: `M queues × N processes` Redis ops/sec; configurable backoff. Wurk should expose a `fetch_poll_interval` knob.

### 3.4 Strict vs weighted queues

```
sidekiq -q critical -q default -q bulk        # strict order
sidekiq -q critical,3 -q default,2 -q bulk,1  # weighted random
```

Implementation: weights are exposed as `Sidekiq.options[:queues]` (array possibly with duplicates).

### 3.5 Metrics

| Metric | When |
| --- | --- |
| `jobs.recovered.fetch` | orphan re-pushed to public queue |
| `jobs.poison`          | poison pill killed |

---

## 4. Reliability — reliable scheduler

```ruby
Sidekiq.configure_server do |config|
  config.reliable_scheduler!
end
```

- Replaces default `ScheduledPoller`.
- Uses one Lua script that **atomically** `ZRANGEBYSCORE` + `ZREM` + `LPUSH` the due jobs into their queue. Default Sidekiq does ZRANGE then ZREM then LPUSH non-atomically — a crash between can lose jobs.
- Incompatible with Redis Cluster (Lua script touches multiple slots).
- No new public Ruby API beyond the activation method.

---

## 5. Reliability — reliable client (Redis-outage buffering)

```ruby
Sidekiq::Client.reliable_push! unless Rails.env.test?
```

- Called at top-level (not inside `Sidekiq.configure_*` blocks).
- Wraps `Sidekiq::Client.push` / `push_bulk`. On `Redis::BaseConnectionError`, jobs are appended to an **in-process** ring buffer (default cap **1000**, configurable via `Sidekiq::Client.reliable_push_buffer = 5_000`).
- Each subsequent `push` first attempts to drain the buffer (oldest-first) before pushing the new job.
- Buffer is **in-memory, per-process**. Crash = lost.
- Does **not** cover `Sidekiq::Batch` creation — batch push raises immediately on Redis failure.
- Statsd: `jobs.recovered.push` increments per drained job.

---

## 6. Queue pause/resume

```ruby
q = Sidekiq::Queue.new("critical")
q.pause!     # writes Redis SET member "critical" → set "paused"
q.paused?    # => true/false
q.unpause!   # SREM
```

- Redis structure: a set named `paused` containing paused queue names.
- Fetcher (`super_fetch` or basic_fetch in Pro mode) skips any queue listed in `paused`. Existing in-flight jobs continue.
- Web UI exposes a "Pause" button per queue when Pro is loaded.

---

## 7. Job expiration — `expires_in`

```ruby
class CacheRefreshJob
  include Sidekiq::Job
  sidekiq_options expires_in: 1.hour
end

# per-push override:
CacheRefreshJob.set(expires_in: 1.day).perform_async(key)
```

Semantics:

- `expires_in` is a **relative** duration. Internally stored as `created_at + duration` (epoch float) on the job hash under key `expiry`.
- Job server middleware checks `expiry` immediately before `perform`; if `Time.now.to_f > expiry`, job is skipped (Statsd `jobs.expired`), counts as **success** for batch purposes, and is not retried.
- Once `perform` starts, expiry does not preempt — long-running jobs that started in time finish.
- For scheduled jobs the clock starts at enqueue, not at schedule time, i.e. `perform_in(2.hours)` + `expires_in: 1.hour` ⇒ expires 3h after enqueue.

---

## 8. `sidekiq_options` additions (Pro only)

| Option | Type | Effect |
| --- | --- | --- |
| `expires_in:` | `Duration` / `Numeric` (seconds) | drop job if not started before expiry |
| `retry: :reliable` | symbol | use Pro's reliable retry encoding (job stays in private queue until ack) — accepted as alias when super_fetch is on |
| `dd_rate:` | Float | Statsd sample rate hint, consumed by the `Statsd.options` proc |

Inherited / unchanged from OSS but worth listing because Pro layers on top: `queue`, `retry`, `dead`, `backtrace`, `tags`, `pool`, `retry_for`.

---

## 9. Statsd / DogStatsd integration

### 9.1 Setup (Pro 7+)

```ruby
require "datadog/statsd"

Sidekiq.configure_server do |config|
  config.dogstatsd = -> {
    Datadog::Statsd.new("metrics.example.com", 8125,
      tags: ["env:#{config[:environment]}", "service:sidekiq"],
      namespace: Rails.application.name
    )
  }

  config.server_middleware do |chain|
    require "sidekiq/middleware/server/statsd"
    chain.add Sidekiq::Middleware::Server::Statsd
  end
end
```

- Pro 7+ requires `dogstatsd-ruby`. `statsd-ruby` support removed.
- Pro 8+ prepends `sidekiq.` to every metric name. Specs below show post-8 names.

### 9.2 Per-job tuning

```ruby
Sidekiq::Middleware::Server::Statsd.options = ->(worker_class, job, queue) {
  {
    tags: ["worker:#{worker_class}", "queue:#{queue}"],
    sample_rate: (job["dd_rate"] || 1.0)
  }
}
```

Disable Datadog extensions (use only base statsd):

```ruby
Sidekiq.configure_server { |c| c[:use_datadog_extensions] = false }
```

### 9.3 Emitted metrics

| Metric (Pro 8+) | Type | Tags |
| --- | --- | --- |
| `sidekiq.jobs.count` | counter | worker, queue |
| `sidekiq.jobs.success` | counter | worker, queue |
| `sidekiq.jobs.failure` | counter | worker, queue |
| `sidekiq.jobs.perform` | gauge (ms) | worker, queue |
| `sidekiq.jobs.perform_dist` | distribution (ms) | worker, queue |
| `sidekiq.jobs.expired` | counter | worker, queue |
| `sidekiq.jobs.recovered.fetch` | counter | queue |
| `sidekiq.jobs.recovered.push` | counter | queue |
| `sidekiq.jobs.poison` | counter | worker, queue |
| `sidekiq.batch.created` | counter | — |
| `sidekiq.batch.duration_dist` | distribution (s) | — |

---

## 10. Web UI — `Sidekiq::Pro::Web`

### 10.1 Mount

```ruby
require "sidekiq/pro/web"

Rails.application.routes.draw do
  mount Sidekiq::Web => "/sidekiq"
end
```

Loading `sidekiq/pro/web` registers extra tabs/actions onto the existing `Sidekiq::Web` Sinatra app:

- **Batches** tab — list of in-progress batches with tree drilldown
- **Dead batches** tab
- Per-queue **Pause/Unpause** button
- **Search box** on Retry / Scheduled / Dead pages (substring across job payload via `ZSCAN`)
- **Filter by tag** in Batches list
- Batch detail page: total/pending/failures, parent/child tree, recent errors

### 10.2 Multi-shard

```ruby
require "sidekiq-pro"
require "sidekiq/pro/web"

POOL1 = Sidekiq::RedisConnection.create(url: "redis://r1/1")
POOL2 = Sidekiq::RedisConnection.create(url: "redis://r2/1")

mount Sidekiq::Web                                 => "/sidekiq"
mount Sidekiq::Pro::Web.with(redis_pool: POOL1),    at: "/sidekiq1"
mount Sidekiq::Pro::Web.with(redis_pool: POOL2),    at: "/sidekiq2"
```

`Sidekiq::Pro::Web.with(redis_pool:)` returns a new Rack app bound to that pool. Used to monitor multiple shards in one process.

### 10.3 Polling endpoint

```ruby
# config.ru
use Sidekiq::Pro::BatchStatus
run Rails.application
```

```
GET /batch_status/<bid>.json
=> {"bid":"...", "total":100, "pending":7, "failures":1,
    "complete":false, "created_at":..., "description":"..."}
```

Returns the JSON of `Sidekiq::Batch::Status#data`. Used by JS to drive progress bars.

---

## 11. Fast Lua API extensions

Pro replaces several O(N)-in-Ruby API methods with Lua scripts run server-side:

```ruby
q = Sidekiq::Queue.new("default")
q.delete_job(jid)             # Lua: LRANGE+LREM on the queue list
q.delete_by_class(MyJob)      # Lua: scan + LREM matching class
q.size                         # standard LLEN, unchanged

Sidekiq::RetrySet.new.scan("NoMethodError")  { |job| job.delete }
Sidekiq::ScheduledSet.new.scan(some_jid)     { |job| ... }
Sidekiq::DeadSet.new.scan("CustomerJob")     { |job| job.retry }
```

`#scan(pattern) { |Sidekiq::JobRecord| ... }` is available on every Pro `SortedSet` subclass (`RetrySet`, `ScheduledSet`, `DeadSet`). Implemented via `ZSCAN` + server-side substring match (Sidekiq 6+ uses sorted-set scan with glob).

Lua scripts are loaded with `SCRIPT LOAD` at boot and cached via `EVALSHA`. Wurk should preload them under `lib/wurk/lua/`.

---

## 12. Behavioural quirks worth pinning down

- **Empty batch** (`b.jobs {}`) — legal Pro 7.1+. Internally inserts `Sidekiq::Batch::Empty` which is a no-op job class so `:complete` and `:success` fire.
- **Batch lifecycle vs ActiveJob** — wiki actively warns against. ActiveJob's own retry layer competes with Sidekiq's, causing miscounted death/success. Pro batches assume native `Sidekiq::Job`.
- **`retry: false` + batches** — never combine. The job's failure won't fire `:death` (no retry → no death event in OSS Sidekiq), so the batch stalls. Pro 7.1 changed this so even `retry: false` jobs that raise fire `:death`.
- **Expired jobs** — count as **success** within a batch. Same for jobs cancelled via `invalidate_all`.
- **24h vs 30d expiries** — see §2.8. The 30d TTL on `b-<bid>-notify` / `b-<bid>-cbsucc` is intentional (lets late-arriving Redis replicas observe callback dedupe) but tunable in Pro 8.
- **Reliable push buffer** — drains lazily, only on the next `push`. Idle clients can stall.
- **Poison pill detection** — counter lives at `super_fetch:recovered:<jid>` with 72h TTL. Threshold 3.
- **Callback retries** — callback jobs themselves retry with the same retry chain as ordinary jobs. A failing `:complete` callback re-runs until it succeeds or dies; this can lead to duplicate side effects → callbacks must be idempotent.
- **Sharded batches** — BID encodes shard hint; `Sidekiq::Batch.new(bid)` routes to the right Redis based on BID prefix. Wurk single-shard MVP can ignore this and treat all BIDs as local.

---

## 13. Wurk implementation checklist (mapping)

| Sidekiq Pro surface | Wurk module target |
| --- | --- |
| `Sidekiq::Batch`, `Status`, `BatchSet`, `DeadSet` | `Wurk::Batch`, `Wurk::Batch::Status`, `Wurk::BatchSet` |
| Batch Lua scripts | `lib/wurk/lua/batch_*.lua` |
| `config.super_fetch!` | `Wurk::Fetch::SuperFetch` (LMOVE-based) |
| `config.reliable_scheduler!` | `Wurk::Scheduler::Reliable` (atomic Lua) |
| `Sidekiq::Client.reliable_push!` | `Wurk::Client.reliable_push!` (in-mem buffer) |
| `Queue#pause!` etc. | `Wurk::Queue#pause!`, `paused` SET |
| `expires_in` | `Wurk::Middleware::Server::Expiry` |
| Statsd | `Wurk::Middleware::Server::Statsd` (dogstatsd) |
| `Sidekiq::Pro::Web` | `Wurk::Web::Pro` mountable Rack/Sinatra app |
| `BatchStatus` polling middleware | `Wurk::Web::BatchStatus` Rack middleware |
| Lua `delete_job`, `delete_by_class`, `scan` | `Wurk::API::Fast` |

Wurk should match method names and arities exactly so existing Sidekiq Pro consumer code drops in unchanged after replacing the `require`.
