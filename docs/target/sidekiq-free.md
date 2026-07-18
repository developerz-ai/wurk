# Sidekiq OSS Public API — Compatibility Spec for Wurk

Target: Sidekiq OSS **8.1.x** (`Sidekiq::VERSION = "8.1.5"`, `MAJOR = 8`).
Scope: free OSS edition only. Anything marked Pro/Ent is documented for awareness but **out of scope** for Wurk.
Goal: wire-compatible drop-in replacement. Redis key schema, JSON job payload format, and public Ruby API surface must match exactly.

Ruby support: `>= 3.2.0`. Redis support: `>= 7.0.0`. License: LGPL-3.0.

---

## 1. Redis Key Schema (canonical — MUST MATCH)

All keys are unprefixed by default (no namespace). Sidekiq Pro/Ent add namespacing; OSS does not.

### 1.1 Queues

| Key | Type | Purpose |
|---|---|---|
| `queues` | SET | set of all known queue names (without `queue:` prefix) |
| `queue:<name>` | LIST | FIFO list of JSON job payloads. `LPUSH` to enqueue, `BRPOP`/`RPUSH` for fetch/requeue |
| `paused` | SET | (Pro) set of paused queue names; OSS reads this but never writes (`Queue#paused?` returns `false`) |

### 1.2 Sorted Sets (Job Sets, score = unix epoch float seconds)

| Key | Purpose |
|---|---|
| `schedule` | jobs scheduled for future execution, score = `at` timestamp |
| `retry` | failed jobs awaiting retry, score = next retry timestamp |
| `dead` | dead jobs (retries exhausted), score = death timestamp |

`Scheduled::SETS = %w[retry schedule]` — poller drains both.

### 1.3 Stats Counters

| Key | Type | Purpose |
|---|---|---|
| `stat:processed` | STRING (int) | global processed count |
| `stat:failed` | STRING (int) | global failed count |
| `stat:processed:YYYY-MM-DD` | STRING (int) | per-day processed, TTL = 5 years |
| `stat:failed:YYYY-MM-DD` | STRING (int) | per-day failed, TTL = 5 years |

`STATS_TTL = 5 * 365 * 24 * 60 * 60` (Launcher).

### 1.4 Process / Worker Heartbeat

| Key | Type | Purpose |
|---|---|---|
| `processes` | SET | identities of live Sidekiq processes |
| `<identity>` | HASH | heartbeat hash for one process, TTL = 60s |
| `<identity>:work` | HASH | currently executing jobs `tid => JSON`, TTL = 60s |
| `<identity>-signals` | LIST | pending signals to send to process, TTL = 60s |
| `process_cleanup` | STRING | rate-limit lock for process cleanup, EX 60 NX |
| `dear-leader` | STRING | (Ent) cluster leader identity; OSS only reads |

`identity` format: `"<hostname>:<pid>:<6-byte-hex-nonce>"` (e.g. `app-1.example.com:1234:abcdef123456`).

Process heartbeat hash fields:

```
info        : JSON of static process metadata
concurrency : total threads across all capsules
busy        : current count of executing jobs
beat        : Time.now.to_f (last heartbeat)
quiet       : "true" | "false"
rss         : memory KB
rtt_us      : Redis RTT in microseconds
```

`info` JSON contents:

```json
{
  "hostname": "...",
  "started_at": <float secs>,
  "pid": 1234,
  "tag": "myapp",
  "concurrency": 5,
  "capsules": {"default": {"concurrency": 5, "mode": "weighted|strict|random", "weights": {"q": w}}},
  "queues": ["q1", "q2"],            // deprecated, derived from capsules
  "weights": [{"q": w}],             // deprecated
  "labels": [],
  "identity": "host:pid:nonce",
  "version": "8.1.5",
  "embedded": false
}
```

Heartbeat cadence: every **10 seconds** (`BEAT_PAUSE = 10`). Key TTL = 60s. Process is considered dead if `info` field missing on lookup.

### 1.5 Iterable Job State

| Key | Type | Purpose |
|---|---|---|
| `it-<jid>` | HASH | iteration state for IterableJob, TTL = 30 days |

Hash fields:
```
ex        : execution count (int)
c         : cursor (JSON string)
rt        : runtime accumulated (float seconds)
cancelled : timestamp (int) if cancelled
```

`STATE_TTL = 30 * 24 * 60 * 60`. `STATE_FLUSH_INTERVAL = 5` seconds. `CANCELLATION_PERIOD = 3 * 86_400` seconds.

### 1.6 Metrics

| Key | Type | Purpose |
|---|---|---|
| `j\|<YYYYMMDD>\|<H>:<M>` | HASH | per-minute job execution metrics, TTL = `MID_TERM` (3 days). Same key Sidekiq writes, so migrated data resolves unchanged |
| `<klass>-<YYYYMMDD>-<H>` | HASH | hourly histogram per class |
| `<YYYYMMDD>-marks` | HASH | deploy marks for day, field=iso8601 ts, value=label, TTL = 90 days |
| `deploylock-<label>` | STRING | per-label deploy mark lock, EX 60 NX |

Per-minute bucket hash fields per job class:
```
<klass>|p   : processed count
<klass>|f   : failed count
<klass>|ms  : total ms spent
```

### 1.7 Profiles (v8.0+)

| Key | Type | Purpose |
|---|---|---|
| `profiles` | ZSET | profile records, score = expiry timestamp |
| `<token>-<jid>` | HASH | profile data (`data`, `sid` fields) |

### 1.8 Lua Scripts

`Scheduled::Enq::LUA_ZPOPBYSCORE` — atomic pop-by-score for retry/schedule sorted sets:
```lua
local key, now = KEYS[1], ARGV[1]
local jobs = redis.call("zrange", key, "-inf", now, "byscore", "limit", 0, 1)
if jobs[1] then
  redis.call("zrem", key, jobs[1])
  return jobs[1]
end
```
Cached as SHA via `SCRIPT LOAD`, retried on `NOSCRIPT`.

---

## 2. Job Payload Format (JSON)

The on-the-wire job is a JSON hash with **string keys** (symbols forbidden — `client_push` raises `ArgumentError` on symbol keys). Stored as JSON in queue lists & sorted sets.

### 2.1 Required fields (set by client at push time)

| Key | Type | Notes |
|---|---|---|
| `class` | String | class name (stringified from `Class` if passed) |
| `args` | Array | JSON-native types only (see `verify_json`) |
| `queue` | String | required, non-empty |
| `jid` | String | 12-byte hex (24 chars), `SecureRandom.hex(12)` |
| `created_at` | Integer | epoch milliseconds (set by `normalize_item`) |
| `retry` | Bool/Integer | true (default 25 attempts) or N |

### 2.2 Optional / context fields

| Key | Type | Notes |
|---|---|---|
| `enqueued_at` | Integer | epoch ms; set on push to immediate queue (not when scheduled). For old format may be Float (epoch secs) |
| `at` | Float | epoch seconds; if present at push → scheduled, removed before enqueue |
| `retry_queue` | String | queue to put retries in (default: same as `queue`) |
| `retry_for` | Numeric | relative seconds; mutually exclusive with retry-count logic. Must be `< 1_000_000_000` |
| `retry_count` | Integer | incremented on each retry |
| `failed_at` | Integer | epoch ms of first failure |
| `retried_at` | Integer | epoch ms of last retry |
| `discarded_at` | Integer | epoch ms when explicitly discarded |
| `error_message` | String | trimmed to 10_000 chars |
| `error_class` | String | exception class name |
| `error_backtrace` | String | base64(zlib(JSON([lines]))) — only when `backtrace` set |
| `backtrace` | Bool/Integer | true = all lines, N = first N |
| `tags` | Array<String> | UI labels |
| `display_class` | String | UI override |
| `wrapped` | String | ActiveJob real class name |
| `bid` | String | (Pro) Batch ID |
| `dead` | Bool | if `false`, skip morgue on retries exhausted |
| `log_level` | String | per-job logger level |
| `locale` | * | (i18n middleware) |
| `cattr`, `cattr_N` | * | (CurrentAttributes middleware) |
| `profile` | * | (Profiler) enable profiling for this job |
| `encrypt` | Bool | (Ent) hint to Web UI to redact last arg |
| `pool` | (transient) | redis pool override; stripped before push |
| `client_class` | (transient) | client class override; stripped before push |

### 2.3 Timestamp formats

- **New format (8.0+)**: integer milliseconds since epoch (`Process.clock_gettime(CLOCK_REALTIME, :millisecond)`).
- **Old format**: Float seconds since epoch. Reader must support both: `if Float → Time.at(ts)`, else `Time.at(ts/1000, ts%1000, :millisecond)`.

### 2.4 Job ID

```
SecureRandom.hex(12)  # 24-char lowercase hex
```

---

## 3. Module `Sidekiq` (top-level)

```ruby
module Sidekiq
  NAME    = "Sidekiq"
  LICENSE = "..."
  VERSION = "8.1.5"
  MAJOR   = 8

  class Shutdown < Interrupt; end   # do not rescue in user code

  # ---- testing/config flags
  def self.testing!(mode = :fake, &block)  # mode in [:fake, :disable, :inline]
  def self.server?     # true if Sidekiq::CLI defined
  def self.pro?        # true if Sidekiq::Pro defined
  def self.ent?        # true if Sidekiq::Enterprise defined

  # ---- JSON
  def self.load_json(string)        # JSON.parse
  def self.dump_json(object)        # JSON.generate

  # ---- Redis
  def self.redis_pool               # current pool (capsule-aware via Thread.current)
  def self.redis(&block)            # yield conn

  # ---- args validation
  def self.strict_args!(mode = :raise)   # :raise | :warn | false

  # ---- default job options
  def self.default_job_options      # default {"retry" => true, "queue" => "default"}
  def self.default_job_options=(h)  # merge in

  # ---- configuration entrypoints
  def self.default_configuration    # Sidekiq::Config singleton
  def self.configure_server(&block) # block runs if server?
  def self.configure_client(&block) # block runs if !server?
  def self.configure_embed(&block)  # returns Sidekiq::Embedded; concurrency=2 default

  def self.logger
  def self.freeze!                  # locks default_configuration

  def self.transactional_push!      # opt-in to TransactionAwareClient (ActiveRecord)
end
```

---

## 4. `Sidekiq::Config`

Global configuration for an instance.

### 4.1 DEFAULTS

```ruby
{
  labels: Set.new,
  require: ".",
  environment: nil,
  concurrency: 5,
  timeout: 25,                                  # shutdown grace seconds
  poll_interval_average: nil,                   # auto = process_count * average_scheduled_poll_interval
  average_scheduled_poll_interval: 5,
  on_complex_arguments: :raise,                 # :raise | :warn | false
  max_iteration_runtime: nil,
  error_handlers: [],                           # default ERROR_HANDLER pushed in
  death_handlers: [],
  lifecycle_events: {
    startup: [], quiet: [], shutdown: [], exit: [],
    heartbeat: [],                              # fires on 1st beat / partition recovery
    beat: []                                    # fires every beat (10s)
  },
  dead_max_jobs: 10_000,
  dead_timeout_in_seconds: 180 * 24 * 60 * 60,  # 6 months
  reloader: proc { |&b| b.call },
  backtrace_cleaner: ->(bt) { bt },
  logged_job_attributes: ["bid", "tags"],
  redis_idle_timeout: nil
}
```

Additional keys read from `@options`:
- `tag`, `identity`, `verbose`, `max_retries`, `fetch_class`, `fetch_setup`,
  `scheduled_enq`, `job_logger`, `skip_default_job_logging`,
  `profile_store_url`, `profile_view_url`.

### 4.2 Public methods

```ruby
class Sidekiq::Config
  attr_reader :capsules
  attr_accessor :thread_priority    # default DEFAULT_THREAD_PRIORITY = -1

  def initialize(options = {})
  def [], []=, fetch, key?, has_key?, merge!, dig   # delegate to @options
  def inspect
  def to_json(*)

  # default capsule shortcuts (writes/reads "default" capsule)
  def concurrency           # default 5
  def concurrency=(val)
  def queues                # default ["default"]
  def queues=(val)          # array of "name" or "name,weight"
  def total_concurrency     # sum across capsules

  # capsules
  def default_capsule(&block)
  def capsule(name) { |cap| ... }     # create/lookup

  # middleware
  def client_middleware { |chain| ... }  # Sidekiq::Middleware::Chain
  def server_middleware { |chain| ... }

  # redis
  def redis=(hash)                  # merge into @redis_config
  def reap_idle_redis_connections(timeout = 60)
  def redis_pool                    # default_capsule's main pool
  def new_redis_pool(size, name)    # via Sidekiq::RedisConnection.create
  def redis_info                    # parses INFO command
  def redis { |conn| ... }          # yield connection with READONLY/NOREPLICAS/UNBLOCKED retry

  # service locator (extension registry)
  def register(name, instance)
  def lookup(name, default_class = nil)

  def freeze!

  # handlers
  def death_handlers                # array of [job, ex] callables
  def error_handlers                # array of [ex, ctx, cfg] callables
  def average_scheduled_poll_interval=(interval)

  # lifecycle hooks
  def on(event, &block)             # event in [:startup, :quiet, :shutdown, :exit, :heartbeat, :beat]

  def logger
  def logger=(logger)
  def handle_exception(ex, ctx = {})  # internal: dispatches to error_handlers
end
```

### 4.3 Default `ERROR_HANDLER`

Logs ex via `cfg.logger.info` using `full_message` (dev/debug) or `detailed_message` (prod), wrapped in `Sidekiq::Context.with(ctx)`.

---

## 5. `Sidekiq::Capsule`

One processing unit (set of threads + queues).

```ruby
class Sidekiq::Capsule
  include Sidekiq::Component
  attr_reader :name, :queues, :mode, :weights
  attr_accessor :concurrency

  def initialize(name, config)
  def to_h                          # {concurrency:, mode:, weights:}
  def fetcher                       # config[:fetch_class] || Sidekiq::BasicFetch
  def stop                          # no-op in OSS

  def queues=(val)
    # accepts:
    #   %w[high default low]          → mode :strict, weights all 0
    #   %w[high,3 default,2 low,1]    → mode :weighted
    #   %w[a,1 b,1 c,1]               → mode :random
    # internal @queues is expanded by weight (e.g. ["high","high","high","default",...])
  end

  def client_middleware { |chain| } # copy_for(self)
  def server_middleware { |chain| }
  def redis_pool                    # main pool: max(@concurrency + 5, 10)
  def fetch_redis_pool              # blocking-BLMOVE fetch pool, size = @concurrency
  def redis { |conn| ... }
  def fetch_redis { |conn| ... }    # checkout from the fetch pool
  def lookup(name)
  def logger
end
```

Modes:
- `:strict` — queues checked in order; first non-empty wins
- `:weighted` — `permute = @queues.shuffle.uniq` each fetch
- `:random` — same shuffle behavior; all weights equal 1

---

## 6. `Sidekiq::Job` (the user-facing mixin)

```ruby
module Sidekiq::Job
  attr_accessor :jid
  attr_accessor :_context   # internal, processor ref

  def logger
  def interrupted?          # @_context&.stopping?
end
```

### 6.1 `Sidekiq::Job::Options` (extended onto any include)

Class-level DSL:

```ruby
class HardJob
  include Sidekiq::Job
  sidekiq_options queue: "critical",
                  retry: 5,                # true | false | Integer
                  backtrace: false,        # true | false | Integer (line count)
                  retry_queue: "low",
                  retry_for: 48.hours,
                  dead: true,
                  tags: [],
                  pool: my_pool,           # transient, stripped
                  client_class: SomeClient # transient, stripped
                  # ... arbitrary options allowed
  sidekiq_retry_in        { |count, ex, jobhash| seconds | :discard | :kill | :default }
  sidekiq_retries_exhausted { |jobhash, ex| ... }
end
```

Class accessors:
- `sidekiq_options_hash` — merged options
- `sidekiq_retry_in_block`
- `sidekiq_retries_exhausted_block`

### 6.2 ClassMethods

```ruby
HardJob.queue_as(q)                # alias for sidekiq_options queue: q
HardJob.perform_async(*args)
HardJob.perform_in(interval, *args)     # alias perform_at
HardJob.perform_at(interval, *args)
HardJob.perform_inline(*args)           # alias perform_sync; bypasses Redis
HardJob.perform_bulk(items, **opts)
HardJob.set(options) → Setter           # returns Setter (see 6.3)
HardJob.client_push(item)               # internal; raises on Symbol keys
HardJob.build_client                    # → Sidekiq::Client
HardJob.delay / delay_for / delay_until # raises ArgumentError (removed)
```

`interval` semantics: if `< 1_000_000_000` treated as seconds-from-now; else absolute timestamp. Past timestamps enqueued immediately (no `at` field).

### 6.3 `Sidekiq::Job::Setter`

```ruby
class Sidekiq::Job::Setter
  include Sidekiq::JobUtil
  def initialize(klass, opts)        # opts string-keyed; wait_until/wait → at
  def set(options)                   # merge more options, returns self
  def perform_async(*args)
  def perform_inline(*args)          # alias perform_sync
  def perform_bulk(args, **opts)
  def perform_in(interval, *args)    # alias perform_at
end
```

`set(sync: true)` makes `perform_async` invoke `perform_inline`.

### 6.4 `Sidekiq::IterableJob`

```ruby
module Sidekiq::IterableJob
  # Cannot define #perform (raises at method_added)
  def build_enumerator(*args, cursor:) end   # MUST return Enumerator yielding [obj, new_cursor]
  def each_iteration(item, *args)     end

  # hooks
  def on_start ; on_resume ; on_stop ; on_cancel ; on_complete
  def around_iteration { yield }

  # state
  attr_reader :current_object
  def arguments
  def cursor
  def cancel!         # sets hash field, async
  def cancelled?
  def iteration_key   # "it-#{jid}"

  # enumerator builders — call from #build_enumerator (cursor parity: array/CSV
  # use the integer index, ActiveRecord uses the record's primary key)
  def array_enumerator(array, cursor:)                       # [item, index]
  def csv_enumerator(csv, cursor:)                           # [row, index]; CSV obj
  def csv_batches_enumerator(csv, cursor:, batch_size: 100)  # [rows_batch, index]
  def active_record_records_enumerator(relation, cursor:, **opts)   # [record, pk]
  def active_record_batches_enumerator(relation, cursor:, **opts)   # [batch, first_pk]
  def active_record_relations_enumerator(relation, cursor:, **opts) # [relation, first_pk]
end

# Enumerator classes also reachable as Sidekiq::Job::Iterable::{CsvEnumerator,
# ActiveRecordEnumerator}. CSV requires the host to have loaded `csv`; the AR
# helpers require ActiveRecord.
class Sidekiq::Job::Interrupted < RuntimeError; end
```

Cancellation: 5-second check interval (`STATE_FLUSH_INTERVAL`). Saved cursor must be JSON-serializable.

---

## 7. `Sidekiq::Client`

```ruby
class Sidekiq::Client
  include Sidekiq::JobUtil
  attr_accessor :redis_pool

  def initialize(pool: nil, config: nil, chain: nil)
  def middleware(&block)            # returns chain; dups if block given

  def push(item) → jid|nil          # nil if middleware halted
  def push_bulk(items) → [jid, ...]

  def cancel!(jid)                  # mark IterableJob cancelled; returns timestamp

  # class methods
  self.push(item)                   # new.push
  self.push_bulk(...)
  self.enqueue(klass, *args)        # → default queue
  self.enqueue_to(queue, klass, *args)
  self.enqueue_to_in(queue, interval, klass, *args)
  self.enqueue_in(interval, klass, *args)
  self.via(pool) { ... }            # thread-local pool override

  private
  def raw_push(payloads)            # pipelined LPUSH/ZADD with retry on READONLY/NOREPLICAS/UNBLOCKED
  def atomic_push(conn, payloads)
end
```

### 7.1 `atomic_push` semantics (CRITICAL for wire-compat)

If `payloads.first["at"]` present (scheduled):
```ruby
conn.zadd("schedule", flat_map { |hash|
  at = hash["at"].to_s
  hash = hash.except("enqueued_at", "at")
  [at, Sidekiq.dump_json(hash)]
})
```

Else (immediate):
```ruby
now = Process.clock_gettime(CLOCK_REALTIME, :millisecond)
grouped = payloads.group_by { |j| j["queue"] }
conn.sadd("queues", grouped.keys)
grouped.each do |queue, jobs|
  payloads = jobs.map { |e| e["enqueued_at"] = now; Sidekiq.dump_json(e) }
  conn.lpush("queue:#{queue}", payloads)
end
```

### 7.2 `push_bulk` options

- `args` — Array of Arrays (one per job)
- `at` — Numeric OR Array<Numeric> same size as args; mutually exclusive with `spread_interval`
- `spread_interval` — positive Numeric, randomly spreads jobs (`max(spread_interval, 5)` floor)
- `batch_size` — default 1000 (or 100 if scheduled)
- `jid` — explicit, only allowed for single-job pushes

Each job gets its own `SecureRandom.hex(12)` jid; runs through middleware individually; returns array of jids (may contain nils for middleware-halted entries).

---

## 8. `Sidekiq::TransactionAwareClient` (opt-in)

```ruby
class Sidekiq::TransactionAwareClient
  def initialize(pool: nil, config: nil)
  def batching?            # Thread.current[:sidekiq_batch]
  def push(item)           # defers to ActiveRecord.after_all_transactions_commit (AR 7.2+)
                           # or after_commit_everywhere gem
                           # pre-allocates jid so caller can use it before commit
  def push_bulk(items)     # NOT transactional
end

Sidekiq.transactional_push!  # sets default_job_options["client_class"]
```

---

## 9. `Sidekiq::JobUtil` (mixin)

```ruby
module Sidekiq::JobUtil
  TRANSIENT_ATTRIBUTES = []   # extended at runtime, currently ["client_class"]

  def validate(item)
    # raises ArgumentError if:
    #  - not Hash with "class" and "args"
    #  - args not Array
    #  - class not Class|String
    #  - at present and not Numeric
    #  - tags present and not Array
    #  - retry_for > 1_000_000_000
  end

  def verify_json(item)
    # JSON-native types only: Integer, Float, true, false, nil, String, Array, Hash<String,*>
    # mode = Sidekiq::Config::DEFAULTS[:on_complex_arguments]
    # :raise → ArgumentError; :warn → warn; false → noop
  end

  def normalize_item(item)
    # 1. validate
    # 2. merge defaults from klass.get_sidekiq_options (or Sidekiq.default_job_options)
    # 3. merge wrapped class options (for ActiveJob)
    # 4. require non-empty "queue"
    # 5. strip TRANSIENT_ATTRIBUTES
    # 6. assign jid (SecureRandom.hex(12)), stringify class & queue
    # 7. coerce retry_for to int if present
    # 8. created_at = now_in_millis
  end

  def now_in_millis      # Process.clock_gettime(CLOCK_REALTIME, :millisecond)
end
```

---

## 10. Middleware

### 10.1 `Sidekiq::Middleware::Chain`

```ruby
class Sidekiq::Middleware::Chain
  include Enumerable
  def initialize(config = nil) { |self| yield }
  def each(&)
  def entries
  def copy_for(capsule)
  def add(klass, *args)               # appends (removes existing first)
  def prepend(klass, *args)           # adds at index 0
  def insert_before(oldklass, newklass, *args)
  def insert_after(oldklass, newklass, *args)
  def remove(klass)
  def exists?(klass)                  # alias include?
  def empty?
  def retrieve                        # → array of fresh instances (calls Entry#make_new)
  def clear
  def invoke(*args, &block)           # runs chain; returns yield result
end

class Sidekiq::Middleware::Chain::Entry
  attr_reader :klass
  def make_new                        # klass.new(*args); sets .config= if respondable
end
```

### 10.2 Middleware contract

Both client and server middleware modules expose:

```ruby
module Sidekiq::ServerMiddleware
  attr_accessor :config
  def redis_pool ; def logger ; def redis(&)
end

Sidekiq::ClientMiddleware = Sidekiq::ServerMiddleware
```

**Client middleware signature:**
```ruby
class MyClientMiddleware
  include Sidekiq::ClientMiddleware
  def call(job_class, job, queue, redis_pool)
    # must yield and RETURN the result (truthy → push proceeds)
    # returning falsy/nil halts the push
    result = yield
    result
  end
end
```

**Server middleware signature:**
```ruby
class MyServerMiddleware
  include Sidekiq::ServerMiddleware
  def call(job_instance, job_hash, queue)
    yield
  end
end
```

### 10.3 Built-in middleware (auto-registered when required)

| Module | Required by user? | Effect |
|---|---|---|
| `Sidekiq::Job::InterruptHandler` | auto (`require "sidekiq/cli"`) | server-side; catches `Sidekiq::Job::Interrupted`, re-pushes job, raises `JobRetry::Skip` |
| `Sidekiq::Metrics::Middleware` | auto (`require "sidekiq/cli"`, embedded) | server-side; tracks per-class p/f/ms |
| `Sidekiq::Middleware::I18n::Client/Server` | `require "sidekiq/middleware/i18n"` | persists `I18n.locale` across job |
| `Sidekiq::CurrentAttributes::Save/Load` | `require "sidekiq/middleware/current_attributes"` and call `persist` | propagates `ActiveSupport::CurrentAttributes` |

`Sidekiq::CurrentAttributes.persist(klass_or_array, config = Sidekiq.default_configuration)` — adds Save to client_middleware, Load to client+server chains. Keys: `"cattr"`, `"cattr_1"`, `"cattr_2"`, ...

---

## 11. `Sidekiq::Component` (mixin)

```ruby
DEFAULT_THREAD_PRIORITY = -1

module Sidekiq::Component
  attr_reader :config

  def real_ms             # CLOCK_REALTIME ms (epoch)
  def mono_ms             # CLOCK_MONOTONIC ms
  def watchdog(last_words) { yield }    # catches & reraises with handle_exception
  def safe_thread(name, priority: nil, &block)
  def logger
  def redis(&)
  def tid                 # Thread-local Sidekiq id: (Thread#object_id ^ Process.pid).to_s(36)
  def hostname            # ENV["DYNO"] || Socket.gethostname
  def process_nonce       # @@process_nonce = SecureRandom.hex(6)
  def identity            # "#{hostname}:#{Process.pid}:#{process_nonce}"
  def handle_exception(ex, ctx = {})
  def fire_event(event, oneshot: true, reverse: false, reraise: false)
  def default_tag(dir = Dir.pwd)
end
```

---

## 12. `Sidekiq::Launcher`

Top-level supervisor.

```ruby
class Sidekiq::Launcher
  include Sidekiq::Component
  STATS_TTL = 5 * 365 * 24 * 60 * 60

  attr_accessor :managers, :poller

  def initialize(config, embedded: false)
  def run(async_beat: true)         # freeze!, start heartbeat thread, poller, managers
  def quiet                         # fire :quiet
  def stop                          # graceful, deadline = now + config[:timeout]
  def stopping?
  def heartbeat                     # one-shot beat (for embedded use)
end
```

`BEAT_PAUSE = 10` seconds.

`flush_stats` increments `stat:processed`, `stat:processed:YYYY-MM-DD` (+TTL), and failed equivalents, atomically pipelined.

`❤` (heartbeat) writes `<identity>` and `<identity>:work` hashes, expires 60s, reads `<identity>-signals` for in-process signals (TSTP/TERM), fires `:heartbeat` (first/recovery) and `:beat` (every) events.

---

## 13. `Sidekiq::Manager`

One per Capsule. Owns the Processor pool.

```ruby
class Sidekiq::Manager
  include Sidekiq::Component
  attr_reader :workers, :capsule

  def initialize(capsule)   # spawns capsule.concurrency Processors
  def start                 # each processor.start
  def quiet                 # processors stop fetching
  def stop(deadline)        # wait for in-flight, then hard_shutdown
  def stopped?
  def processor_result(processor, reason = nil)  # replace-on-die
end
```

`PAUSE_TIME = 0.5` (0.1 in TTY). On hard shutdown, in-flight jobs are `bulk_requeue`d before threads killed.

---

## 14. `Sidekiq::Processor`

```ruby
class Sidekiq::Processor
  include Sidekiq::Component
  attr_reader :thread, :job, :capsule

  PROCESSED   = Counter.new       # global atomic counter
  FAILURE     = Counter.new
  WORK_STATE  = SharedWorkState.new   # tid => {queue:, payload:, run_at:}

  def initialize(capsule, &callback)
  def terminate(wait = false)
  def kill(wait = false)            # raises Sidekiq::Shutdown in thread
  def stopping?
  def start                         # safe_thread("<cap>/processor")
end

class Sidekiq::Processor::Counter
  def incr(n=1) ; def reset
end

class Sidekiq::Processor::SharedWorkState
  def set(tid, hash) ; def delete(tid) ; def dup ; def size ; def clear
end
```

Job lifecycle inside `#process`:

1. `Sidekiq.load_json(jobstr)` — on parse fail, job goes straight to `dead` set, ack, return.
2. Wrap in `Thread.handle_interrupt(Shutdown => :never)` / `:immediate` toggles.
3. `dispatch(job_hash, queue, jobstr)`:
   - `@job_logger.prepare(job_hash)` (sets thread context)
   - `@retrier.global(jobstr, queue)`
   - `@job_logger.call(job_hash, queue)`
   - `stats(jobstr, queue)` (sets WORK_STATE; incr counters in ensure)
   - `profile(job_hash)` (if `"profile"` set)
   - `@reloader.call` (Rails reloader)
   - instantiate `Object.const_get(job_hash["class"]).new`
   - `instance.jid = job_hash["jid"]`; `instance._context = self`
   - `@retrier.local(instance, jobstr, queue)`
4. Server middleware chain → `execute_job(instance, args)` → `instance.perform(*args)`
5. `uow.acknowledge` on success (or `Skip`/`Handled`); on `Shutdown` do NOT ack (job will be requeued).

---

## 15. `Sidekiq::BasicFetch`

```ruby
class Sidekiq::BasicFetch
  include Sidekiq::Component
  TIMEOUT = 2     # seconds; BRPOP loops

  UnitOfWork = Struct.new(:queue, :job, :config) do
    def acknowledge ; end     # OSS: no-op
    def queue_name            # queue.delete_prefix("queue:")
    def requeue               # RPUSH back to original queue
  end

  def initialize(capsule)
  def retrieve_work → UnitOfWork|nil   # BRPOP queues_cmd
  def bulk_requeue(inprogress)         # pipelined RPUSH grouped by queue
  def queues_cmd                       # strict: @queues; else shuffle.uniq
end
```

Pluggable via `config[:fetch_class]` + `config[:fetch_setup]`.

---

## 16. `Sidekiq::Scheduled`

```ruby
module Sidekiq::Scheduled
  SETS = %w[retry schedule]

  class Enq
    include Sidekiq::Component
    LUA_ZPOPBYSCORE = "..."
    def initialize(container)
    def enqueue_jobs(sorted_sets = SETS)
    def terminate
  end

  class Poller
    include Sidekiq::Component
    INITIAL_WAIT = 10
    attr_accessor :rnd

    def initialize(config)
    def start                  # safe_thread("scheduler")
    def terminate
    def enqueue                # → @enq.enqueue_jobs (error-caught)

    private
    def random_poll_interval   # spread across process_count * average_scheduled_poll_interval
    def poll_interval_average(count)
    def scaled_poll_interval(count)
    def process_count          # SCARD processes (min 1)
    def cleanup                # prune dead processes (rate-limited to 1/min)
  end
end
```

Polling math: `interval = process_count * average_scheduled_poll_interval`. Below 10 processes: jitter `interval * rand + interval/2`. At 10+: `interval * rand * 2`.

Pluggable via `config[:scheduled_enq]`.

---

## 17. `Sidekiq::JobRetry`

```ruby
class Sidekiq::JobRetry
  include Sidekiq::Component
  DEFAULT_MAX_RETRY_ATTEMPTS = 25

  class Handled < RuntimeError; end
  class Skip < Handled; end

  def initialize(capsule)
  def global(jobstr, queue) { yield }     # rescues Exception → process_retry
  def local(jobinst, jobstr, queue) { yield }  # rescues Exception → process_retry; raises Handled
end
```

### 17.1 Retry delay algorithm

```
delay = (count ** 4) + 15       # seconds; default formula
jitter = rand(10 * (count + 1))
retry_at = now + delay + jitter

# 25 retries ≈ ~21 days total
```

`sidekiq_retry_in` block can return:
- positive Integer → use as `delay` (seconds)
- `:discard` — job is silently dropped (death_handlers run, but not morgue), `discarded_at` set
- `:kill` — job goes to dead set
- `:default` / nil — use default formula

### 17.2 Retries exhausted

Triggered when `retry_count >= retry_attempts_from(msg["retry"], max_retries)`, or `retry_for` time exceeded.

- Runs `sidekiq_retries_exhausted` block (or wrapped class's)
- If block returns `:discard` OR `msg["dead"] == false` → set `discarded_at`, run death_handlers, do NOT add to morgue
- Else: `send_to_morgue` (ZADD `dead`, trim by `dead_timeout_in_seconds` & `dead_max_jobs`)
- Run `config.death_handlers`

### 17.3 Error payload added to msg

```
error_message     : ex.message[0,10_000] (UTF-8 scrubbed)
error_class       : ex.class.name
retry_count       : 0 first time, +1 each retry
failed_at         : ms epoch (set on first failure only)
retried_at        : ms epoch (set on retries)
error_backtrace   : if msg["backtrace"]: base64(Zlib.deflate(JSON.dump(lines)))
                    where lines = full or first N from msg["backtrace"]
```

---

## 18. `Sidekiq::JobLogger`

```ruby
class Sidekiq::JobLogger
  def initialize(config)
  def call(item, queue) { yield }
  def prepare(job_hash, &)
end
```

Logs `"start"` / `"done"` / `"fail"` at INFO. `Sidekiq::Context.add(:elapsed, ms)`. Respects `config[:skip_default_job_logging]`. Per-job `log_level`. Thread-local context hash populated from `config[:logged_job_attributes]` (default `["bid","tags"]`).

Pluggable via `config[:job_logger]`.

---

## 19. Data API — `lib/sidekiq/api.rb` (`require "sidekiq/api"`)

Never used by Sidekiq server itself. Read/manipulate Redis state from clients.

### 19.1 `Sidekiq::Stats`

```ruby
class Sidekiq::Stats
  QueueSummary = Data.define(:name, :size, :latency, :paused) { alias_method :paused?, :paused }

  def initialize                       # eager fetch_stats_fast!
  def processed                        # GET stat:processed
  def failed
  def scheduled_size                   # ZCARD schedule
  def retry_size
  def dead_size
  def enqueued                         # sum LLEN over all queues (slow)
  def processes_size                   # SCARD processes
  def workers_size                     # sum busy across processes (slow)
  def default_queue_latency
  def queues → {name => size}
  def queue_summaries → [QueueSummary]
  def reset(*stats)                    # default ["processed","failed"]
end

class Sidekiq::Stats::History
  def initialize(days_previous, start_date = nil, pool: nil)   # 1..1825
  def processed → {YYYY-MM-DD => count}
  def failed
end
```

### 19.2 `Sidekiq::Queue`

```ruby
class Sidekiq::Queue
  include Enumerable
  attr_reader :name
  alias id name

  def self.all → [Queue]               # SSCAN queues
  def initialize(name = "default")
  def size                             # LLEN
  def paused?                          # false in OSS
  def latency → Float                  # secs since last item enqueued
  def each { |JobRecord| ... }         # paged LRANGE (page_size = 50)
  def find_job(jid) → JobRecord|nil    # O(n)
  def clear → true                     # UNLINK + SREM queues
  alias 💣 clear
  def as_json(_=nil) → {name:}
end
```

### 19.3 `Sidekiq::JobRecord`

```ruby
class Sidekiq::JobRecord
  include ApiUtils
  attr_reader :item, :value, :queue

  def initialize(item, queue_name = nil)
  def klass                            # item["class"]
  def display_class                    # unwraps ActionMailer/AJ
  def display_args
  def args
  def jid
  def iterable_state                   # → IterableJobQuery::State|nil
  def bid                              # item["bid"]
  def failed_at → Time|nil
  def retried_at
  def enqueued_at
  def created_at
  def tags
  def error_backtrace                  # decoded from base64+zlib
  def latency
  def delete → Boolean                 # LREM queue:<q> 1 @value
  def [](name)
end
```

### 19.4 `Sidekiq::SortedEntry < JobRecord`

```ruby
class Sidekiq::SortedEntry < Sidekiq::JobRecord
  attr_reader :parent
  def initialize(parent, score, item)
  def score → Float
  def id → "<score>|<jid>"
  def at → Time
  def delete                           # @parent.delete_by_value/jid
  def reschedule(at)                   # ZINCRBY
  def add_to_queue                     # remove + Client.push (resets retry_count - 1)
  def retry                            # remove + Client.push, decrements retry_count
  def kill                             # remove + DeadSet#kill
  def error?
end
```

### 19.5 `Sidekiq::SortedSet` / `JobSet` / Sets

```ruby
class Sidekiq::SortedSet
  include Enumerable
  attr_reader :name
  def size                       # ZCARD
  def scan(match, count = 100)   # ZSCAN with "*match*"
  def clear → true               # UNLINK
  alias 💣 clear
  def as_json
end

class Sidekiq::JobSet < SortedSet
  def schedule(timestamp, job)
  def pop_each { |data, score| ... }   # ZPOPMIN loop
  def retry_all
  def kill_all(notify_failure: false, ex: nil)
  def each { |SortedEntry| ... }       # reverse paged ZRANGE
  def fetch(score, jid = nil) → [SortedEntry]   # score Time|Range
  def find_job(jid)                    # ZSCAN by "*jid*"
  def remove_job(entry)
  def delete_by_value(name, value)
  def delete_by_jid(score, jid)
  alias delete delete_by_jid
end

class Sidekiq::ScheduledSet < JobSet ; def initialize ; super("schedule") ; end
class Sidekiq::RetrySet     < JobSet ; def initialize ; super("retry")    ; end
class Sidekiq::DeadSet      < JobSet
  def initialize ; super("dead") ; end
  def trim                                  # within dead_max_jobs & dead_timeout
  def kill(message, opts = {})              # ZADD dead + trim + death_handlers
    # opts: notify_failure (def true), trim (def true), ex (RuntimeError)
end
```

### 19.6 `Sidekiq::ProcessSet`

```ruby
class Sidekiq::ProcessSet
  include Enumerable
  def self.[](identity) → Process|nil
  def initialize(clean_plz = true)
  def cleanup → count                  # rate-limited 1/min, SREM dead identities
  def each { |Process| ... }
  def size                             # SCARD (not pruned)
  def total_concurrency
  def total_rss_in_kb       # alias total_rss
  def leader → String       # GET dear-leader (Ent only)
end

class Sidekiq::Process
  def tag
  def labels
  def [](key)
  def identity              # alias id
  def queues                # back-compat
  def weights
  def capsules
  def version
  def embedded?
  def quiet!                # LPUSH <id>-signals "TSTP"
  def stop!                 # LPUSH <id>-signals "TERM"
  def dump_threads          # LPUSH "TTIN"
  def stopping?             # self["quiet"] == "true"
  def leader?               # check dear-leader
end
```

### 19.7 `Sidekiq::WorkSet` / `Sidekiq::Work`

```ruby
class Sidekiq::WorkSet
  include Enumerable
  def each { |pid, tid, Work| ... }    # iterate <id>:work hashes
  def size                             # sum busy field across processes
  def find_work(jid)                   # alias find_work_by_jid
end

Sidekiq::Workers = Sidekiq::WorkSet     # deprecated alias

class Sidekiq::Work
  attr_reader :process_id, :thread_id
  def queue
  def run_at                           # Time.at(hsh["run_at"])
  def job → JobRecord
  def payload                          # raw JSON string
end
```

### 19.8 `Sidekiq::ProfileSet` / `ProfileRecord`

```ruby
class Sidekiq::ProfileSet
  include Enumerable
  def initialize                       # ZREMRANGEBYSCORE profiles + ZRANGE
  def size ; def each { |ProfileRecord| }
end

class Sidekiq::ProfileRecord
  attr_reader :started_at, :jid, :type, :token, :size, :elapsed
  def key  → "<token>-<jid>"
  def data → blob
end
```

### 19.9 `Sidekiq::IterableJobQuery`

```ruby
class Sidekiq::IterableJobQuery
  def initialize(jids)    # bulk pipelined HGETALL it-<jid>
  def [](jid) → State|nil
end

Sidekiq::IterableJobQuery::State = Struct.new(:jid, :raw) do
  def executions ; def runtime ; def cursor ; def cancelled
end
```

---

## 20. Metrics API — `Sidekiq::Metrics::Query`

```ruby
class Sidekiq::Metrics::Query
  ROLLUPS = {
    minutely: [60,  ->(time) { time.strftime("j|%y%m%d|%-H:%M") }],
    hourly:   [600, ->(time) { ... "j|%y%m%d|%-H:#{mins}" }]
  }
  def initialize(pool: nil, now: Time.now)
  def top_jobs(class_filter: nil, minutes: nil, hours: nil) → Result
  def for_job(klass, minutes: nil, hours: nil) → Result
  def self.bkt_time_s(time, granularity)
end

class Sidekiq::Metrics::Query::Result < Struct.new(:granularity, :starts_at, :ends_at, :size, :job_results, :marks)
class Sidekiq::Metrics::Query::JobResult < Struct.new(:granularity, :series, :hist, :totals)
  def add_metric(metric, time, value)
  def add_hist(time, hist_result)
  def total_avg(metric = "ms")
  def series_avg(metric = "ms")
end

Sidekiq::Metrics::Query::MarkResult = Struct.new(:time, :label, :bucket)
```

DoS caps: `minutes <= 480` (8h), `hours <= 72`. Histograms only fetched for minute-grained queries.

---

## 21. CLI — `bin/sidekiq`

`Sidekiq::CLI` is a singleton (`Sidekiq::CLI.instance`).

### 21.1 Option parser

```
-c, --concurrency INT       processor threads (alias RAILS_MAX_THREADS env)
-e, --environment ENV       app env (alias APP_ENV/RAILS_ENV/RACK_ENV)
-g, --tag TAG               process tag for procline
-q, --queue QUEUE[,WEIGHT]  repeatable; weights → :weighted mode
-r, --require [PATH|DIR]    rails app dir or single .rb file
-t, --timeout NUM           shutdown timeout (default 25s)
-v, --verbose               DEBUG level logging
-C, --config PATH           YAML config file path (or sidekiq.yml(.erb))
-V, --version
-h, --help
```

### 21.2 YAML config

Auto-discovered at `<require>/config/sidekiq.yml` or `sidekiq.yml.erb`.

```yaml
:concurrency: 5
:queues:
  - default
  - [critical, 2]
:capsules:
  high_priority:
    :concurrency: 3
    :queues:
      - critical
production:
  :concurrency: 10
```

Environment overlays merged from `opts[environment.to_sym]`.

### 21.3 Signals

| Signal | Effect |
|---|---|
| `INT`, `TERM` | shutdown (raises `Interrupt`) |
| `TSTP` | quiet (stop fetching new jobs) |
| `TTIN` | dump thread backtraces to log |
| `INFO` | deprecated; same as TTIN |
| `USR2` | (Pro only) |

`SIGNAL_HANDLERS` hash — extensible.

### 21.4 Lifecycle (CLI#run)

1. `boot_application` (Rails or `require @config[:require]`)
2. Validate Redis >= 7.0, warn on non-`noeviction` maxmemory policy
3. Validate pool size per capsule ≥ concurrency
4. `Process.warmup` (Ruby 3.3+) unless `RUBY_DISABLE_WARMUP=1`
5. `fire_event(:startup, reraise: true)`
6. `Sidekiq::Launcher.new(@config).run`
7. Signal loop on self-pipe

---

## 22. `Sidekiq::Embedded`

```ruby
class Sidekiq::Embedded
  include Sidekiq::Component
  def initialize(config)
  def run                  # housekeeping; fire :startup; launcher.run; sleep 0.2
  def quiet                # @launcher.quiet
  def stop                 # @launcher.stop
end
```

Concurrency defaulted to 2. `embedded: true` flag set in heartbeat.

---

## 23. `Sidekiq::Deploy`

```ruby
class Sidekiq::Deploy
  MARK_TTL = 90 * 24 * 60 * 60
  LABEL_MAKER = -> { `git log -1 --format="%h %s"`.strip }

  def self.mark!(label = nil)
  def initialize(pool = Sidekiq::RedisConnection.create)
  def mark!(at: Time.now, label: nil)
    # rounds at to minute, writes HSET <YYYYMMDD>-marks <iso8601> <label>
    # uses "deploylock-<label>" SET NX EX 60 to dedupe per minute
  def fetch(date = Time.now.utc.to_date) → {iso8601 => label}
end
```

---

## 24. `Sidekiq::Testing` & test API

`require "sidekiq/testing"` is deprecated (warning); 8.0+ uses `Sidekiq.testing!(:fake|:disable|:inline, &block)`.

### 24.1 `Sidekiq::Testing`

```ruby
class Sidekiq::Testing
  class TestModeAlreadySetError < RuntimeError; end

  self.disable! { ... }
  self.fake!    { ... }
  self.inline!  { ... }
  self.enabled? ; .disabled? ; .fake? ; .inline?
  self.server_middleware { |chain| ... }    # in-process server chain for inline mode

  def self.__set_test_mode(mode, &block)    # block → thread-local; no block → global
end

class Sidekiq::EmptyQueueError < RuntimeError; end
```

### 24.2 `Sidekiq::Queues` (test-mode fake queue store)

```ruby
module Sidekiq::Queues
  self.[](queue)         # jobs_by_queue[queue]
  self.push(queue, klass, job)
  self.jobs_by_queue
  self.jobs_by_class     # alias jobs_by_worker
  self.delete_for(jid, queue, klass)
  self.clear_for(queue, klass)
  self.clear_all
end
```

### 24.3 `Sidekiq::Job` testing extensions

When testing required:
```ruby
HardJob.queue          # get_sidekiq_options["queue"]
HardJob.jobs           # Queues.jobs_by_class[to_s]
HardJob.clear
HardJob.drain          # run & remove all
HardJob.perform_one    # run & remove first, raises EmptyQueueError if empty
HardJob.process_job(job_hash)
HardJob.execute_job(worker, args)

Sidekiq::Job.jobs       # flat all queue jobs
Sidekiq::Job.clear_all
Sidekiq::Job.drain_all
```

In `:inline!` mode, `Sidekiq::Client#atomic_push` is monkey-patched (via `Sidekiq::TestingClient`) to immediately `klass.process_job(job_hash)`.

In `:fake!` mode, payloads go into the in-memory `Queues`. `enqueued_at` set to current ms (unless scheduled).

---

## 25. `Sidekiq::Web` (Web UI)

### 25.1 Entrypoint

```ruby
require "sidekiq/web"
# Rack-compatible:
run Sidekiq::Web         # class with self.call(env)

Sidekiq::Web.app_url = "https://myapp.com"
Sidekiq::Web.assets_path = "/path/to/assets"
Sidekiq::Web.redis_pool = my_pool
Sidekiq::Web.use(Rack::Auth::Basic) { |u,p| ... }
Sidekiq::Web.configure do |cfg| cfg.register(ext, ...) end
```

CSRF: same-site requests only (`HTTP_SEC_FETCH_SITE == "same-origin"`); unsafe methods denied → 403. Heartbeat: `HEAD /` calls `LLEN queue:default`.

### 25.2 `Sidekiq::Web::Config`

```ruby
class Sidekiq::Web::Config
  OPTIONS = {
    profile_view_url:  "https://profiler.firefox.com/public/%s",
    profile_store_url: "https://api.profiler.firefox.com/compressed-store"
  }

  attr_accessor :custom_job_info_rows, :app_url, :assets_path
  attr_reader   :tabs, :locales, :views, :middlewares

  def [], []=, fetch, key?, has_key?, merge!, dig  # delegates @options
  def use(*args, &block)
  def register_extension(extclass, name:, tab:, index:, root_dir: nil, cache_for: 86400, asset_paths: nil)
  alias register register_extension
end
```

### 25.3 Default tabs

```ruby
DEFAULT_TABS = {
  "Dashboard" => "",
  "Busy"      => "busy",
  "Queues"    => "queues",
  "Retries"   => "retries",
  "Scheduled" => "scheduled",
  "Dead"      => "morgue",
  "Metrics"   => "metrics",
  "Profiles"  => "profiles"
}
```

### 25.4 Routes

| Method | Path | Purpose |
|---|---|---|
| HEAD | `/` | health check (Redis LLEN) |
| GET | `/` | dashboard (renders `:dashboard`); `?days=N` (1..180) |
| GET | `/busy` | currently executing jobs; `?count=`, `?page=` |
| POST | `/busy` | params: `identity`, `quiet`, `stop` (per-process or all) |
| GET | `/queues` | list queues |
| GET | `/queues/:name` | queue contents; `?count=`, `?page=`, `?direction=asc` |
| POST | `/queues/:name` | clear (or pause/unpause if Pro) |
| POST | `/queues/:name/delete` | delete single job by `key_val` |
| GET | `/retries` | retry set; `?substr=`, `?count=`, `?page=` |
| GET | `/retries/:key` | single retry; key = `"<score>-<jid>"` |
| POST | `/retries` | bulk action (`key[]`, params retry/delete/kill) |
| POST | `/retries/all/delete` | clear retry set |
| POST | `/retries/all/retry` | retry_all |
| POST | `/retries/all/kill` | kill_all |
| POST | `/retries/:key` | single action |
| GET | `/scheduled` | schedule set; `?substr=`, etc. |
| GET | `/scheduled/:key` | single |
| POST | `/scheduled` | bulk (delete/add_to_queue) |
| POST | `/scheduled/:key` | single |
| POST | `/scheduled/all/delete` | clear |
| POST | `/scheduled/all/add_to_queue` | enqueue all |
| GET | `/morgue` | dead set; `?substr=` |
| GET | `/morgue/:key` | single dead job |
| POST | `/morgue` | bulk action |
| POST | `/morgue/all/delete` | clear |
| POST | `/morgue/all/retry` | retry_all |
| POST | `/morgue/:key` | single action |
| GET | `/metrics` | `?period=1h..72h`, `?substr=` |
| GET | `/metrics/:name` | per-class |
| GET | `/dashboard/stats` | 302 → `/stats` |
| GET | `/stats` | JSON stats (`sidekiq`, `redis`, `server_utc_time`) |
| GET | `/stats/queues` | JSON queue sizes |
| GET | `/profiles` | profile list |
| GET | `/profiles/:key` | upload to Firefox profiler & redirect |
| GET | `/profiles/:key/data` | gzipped raw profile JSON |
| POST | `/change_locale` | session-stored locale |

`QUEUE_NAME = /\A[a-z_:.\-0-9]+\z/i`

Route param syntax: `:name` → `route_params(:name)` (Symbol); query params → `url_params("name")` (String).

### 25.5 Web router DSL

```ruby
module Sidekiq::Web::Router
  def head/get/post/put/patch/delete(path, &block)
  def route(*methods, path, &block)
  def match(env) → Action|nil
end

class Sidekiq::Web::Route
  NAMED_SEGMENTS_PATTERN = %r{/([^/]*):([^.:$/]+)}
  def matcher              # compiled regex or string
  def match(method, path)
end
```

### 25.6 `Sidekiq::Web::Action`

```ruby
class Sidekiq::Web::Action
  attr_accessor :env, :block
  def config                       # env[:web_config]
  def request                      # Rack::Request
  def halt(res)                    # throw :halt, [code, headers, body]
  def redirect_to(url)             # external
  def redirect(location)           # internal (request.base_url prepended)
  def header(key, value)
  def reload_page
  def url_params(key)              # String keys only
  def route_params(key)            # Symbol keys only
  def params
  def session
  def logger
  def flash { ... } ; def flash? ; def get_flash
  def erb(content, options = {})   # caches compiled ERB
  def render(:erb, content, options = {})
  def json(payload)                # JSON 200 response
end
```

Layout: `web/views/layout.html.erb`. Views: `web/views/*.html.erb`.

### 25.7 `Sidekiq::WebHelpers` (included in Action via `Web::Application.helpers`)

Notable methods: `store_name`, `store_version`, `style_tag`, `script_tag`, `strings(lang)`, `parse_yaml_new`, `to_json`, `available_locales`, `language_name(locale)`, `search(jobset, substr)`, `filter_link`, `display_tags`, `add_to_head`, `text_direction`, `rtl?`, `locale`, `t(msg, options={})`, `workset`, `processes`, `sorted_processes`, `stats`, `redis_url`, `redis_info`, `root_path`, `current_path`, `current_status`, `relative_time(t)`, `job_params(job, score)`, `parse_key(key)`, `qparams(opts)`, `to_query_string(h)`, `truncate(text, n=2000)`, `display_args`, `csrf_tag`, `csp_nonce`, `retry_or_delete_or_kill(job, params)`, `delete_or_add_queue(job, params)`, `format_memory(kb)`, `number_with_delimiter(n)`, `h(text)`, `environment_title_prefix`, `product_version`, `server_utc_time`, `pollable?`.

`RETRY_JOB_KEYS` = set of known job fields for extra-info display.

`SAFE_QPARAMS = %w[page direction]`.

CSP nonce per request: `SecureRandom.hex(8)`. Cache headers: `private, no-store`.

---

## 26. `Sidekiq::RedisConnection`

```ruby
module Sidekiq::RedisConnection
  def self.create(options = {})    # returns ConnectionPool of RedisClientAdapter
end
```

Default URL: `ENV["REDIS_URL"]` or `redis://localhost:6379/0`. Adapter: `redis-client`. The pool is `connection_pool` gem's `ConnectionPool`.

Pool size defaults: per-capsule = `cap.concurrency`; internal/housekeeping = 10.

Retry policy on conn-level errors (`READONLY`, `NOREPLICAS`, `UNBLOCKED`): close + retry once.

---

## 27. Component glue / lifecycle events

Events (`config.on(:event)`):
- `:startup` — fired once, before threads spin up (Manager start). `reraise: true`.
- `:quiet` — fired on quiet signal. `reverse: true`.
- `:shutdown` — during stop. `reverse: true`.
- `:exit` — at very end of `stop`. `reverse: true`.
- `:heartbeat` — on first heartbeat or partition recovery.
- `:beat` — every 10s; **NOT oneshot** (`oneshot: false`).

All but `:beat` are oneshot (cleared after firing).

---

## 28. ActiveJob integration

ActiveJob adapter class: `ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper` (also aliased `Sidekiq::ActiveJob::Wrapper`). Job hash has:
- `class` = `"ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"`
- `wrapped` = real job class name
- `args` = `[{ "job_class": ..., "arguments": [...], ... }]`

`JobRecord#display_class` / `display_args` unwrap these (and ActionMailer's `DeliveryJob` / `MailDeliveryJob`).

---

## 29. Logger

`Sidekiq::Logger` — `Logger` subclass. Default level INFO. Formatters:
- `Sidekiq::Logger::Formatters::Pretty` (TTY default)
- `Sidekiq::Logger::Formatters::WithoutTimestamp` (when `ENV["DYNO"]` set)
- `Sidekiq::Logger::Formatters::JSON` (opt-in)

`Sidekiq::Context.with(hash) { ... }` / `Sidekiq::Context.add(k, v)` — Thread-local logging context (`Thread.current[:sidekiq_context]`).

---

## 30. Loader

`Sidekiq::Loader` — `Sidekiq.loader` singleton, runs hooks: `run_load_hooks(:api)` fired at end of `api.rb`. Used by extensions (sidekiq-pro, sidekiq-cron) to hook in.

---

## 31. Implementation notes / gotchas (critical for compat)

1. **Symbol keys are forbidden** in job payloads at push time (`client_push` raises `ArgumentError`). Internal storage = string keys.
2. **JSON-only args**: `verify_json` walks args recursively; `Hash` keys MUST be Strings. `Symbol`, `Date`, `Time`, custom classes → error/warn per `on_complex_arguments`.
3. **`at` semantics**: a Numeric `< 1_000_000_000` is treated as relative seconds-from-now; `>=` is absolute epoch. Past `at` → enqueue immediately (no `at` field).
4. **Immediate jobs** go to `queue:<name>` (LPUSH, BRPOP fetch — so FIFO from tail). Scheduled jobs go to `schedule` ZSET; poller pops eligible ones with `ZRANGE BYSCORE LIMIT 0 1` + `ZREM` (Lua atomic) and re-pushes via `Client#push`.
5. **`enqueued_at` is integer ms** on writes (since 8.x); read code must handle Float (old) and Integer (new). `created_at` set on every push.
6. **Process identity**: change of `process_nonce` per process; identity sticky for process lifetime. After fork, `tid` re-computed via Process.pid XOR.
7. **Retry queue routing**: `msg["queue"] = msg["retry_queue"] || queue`. The original queue is lost across retries.
8. **Dead set trim** happens on every kill: `ZREMRANGEBYSCORE dead -inf (now - dead_timeout)` + `ZREMRANGEBYRANK dead 0 -dead_max_jobs`.
9. **Malformed JSON jobs** go straight to `dead` (with ZADD using raw payload as member, score now).
10. **`UnitOfWork#acknowledge`** is a no-op in OSS (reliable fetch is Pro-only).
11. **`bulk_requeue` on hard shutdown** uses `RPUSH` (head of queue, FIFO preserved).
12. **`stat:processed` / `stat:failed`** are pipelined and incremented at every heartbeat (10s) by `flush_stats` — NOT immediately after each job (PROCESSED/FAILURE are in-process counters).
13. **`workers` count** = sum of `busy` HASH field across processes (set in `❤`, not real-time).
14. **`paused` set** is read but never written in OSS — `Queue#paused?` always returns `false`.
15. **Random JIDs**: `SecureRandom.hex(12)` — exactly 24 lowercase hex chars.
16. **Heartbeat clears `<identity>:work`** on each beat: `UNLINK` + repopulate. Means a "lost" beat after a job started will momentarily empty the work set in Redis.
17. **Process cleanup** in `ProcessSet#cleanup`: rate-limited via `SET process_cleanup "1" NX EX 60`. Prunes identities whose `info` field is gone (TTL expired).
18. **Web UI session required** (Rack::Session::Cookie or Rails session). Used for flash + locale.
19. **No namespacing** in OSS — Pro adds optional key prefix. Wurk should match OSS exactly (no prefix).
20. **Lua script caching**: load via `SCRIPT LOAD`, store SHA per-process, retry on `NOSCRIPT`.

---

## 32. Out of scope (Pro/Enterprise — DO NOT implement)

For reference: features above are sometimes invoked from OSS code paths (graceful no-op when gem not loaded).

- `Sidekiq::Batch` / `bid` — Pro
- Reliable fetch / super_fetch — Pro
- Queue pausing (`Queue#pause!`, `Queue#unpause!`) — Pro
- Encrypted args — Ent
- Rate limiting — Ent
- Periodic jobs (cron) — Ent
- Web UI authorization roles — Ent
- Unique jobs — Ent
- Leader election (`dear-leader` key) — Ent
- `Sidekiq::ActiveJob::Wrapper` retry/exhausted blocks read in OSS for compat

`Sidekiq.pro?` / `Sidekiq.ent?` are the gates — Wurk should return `false` from both.

---

## 33. Minimum implementation checklist for wire-compat

- [ ] All Redis keys above with exact names and types
- [ ] JSON payload format with all required + commonly-used optional fields
- [ ] `Sidekiq` top-level module with `redis`, `redis_pool`, `default_configuration`, `configure_server/client/embed`, `default_job_options`, `dump_json/load_json`, `strict_args!`, `Shutdown` exception
- [ ] `Sidekiq::Job` mixin + `sidekiq_options` + `perform_async/in/at/bulk/inline` + `Setter`
- [ ] `Sidekiq::Client` with `push`, `push_bulk`, `via`, `enqueue*`
- [ ] Atomic push (LPUSH for queue, ZADD for schedule) — exact serialization
- [ ] `Sidekiq::Middleware::Chain` with `add/prepend/insert_before/insert_after/remove/invoke`
- [ ] Server processing loop: BRPOP → JSON parse (or → dead) → middleware → perform → retry/ack
- [ ] Retry algorithm: `count**4 + 15 + jitter`, `retry_queue`, `retry_for`, `sidekiq_retry_in`, `sidekiq_retries_exhausted`
- [ ] Dead set trim (max_jobs + timeout)
- [ ] Scheduler poll with Lua zpopbyscore
- [ ] Heartbeat (10s) writing `<identity>` HASH + `<identity>:work` + `processes` SADD + `<identity>-signals` LIST drain
- [ ] Per-day stats counters with 5y TTL
- [ ] `stat:processed` / `stat:failed` aggregate counters
- [ ] Capsule abstraction (concurrency, queues, weights, modes)
- [ ] CLI with same options + sidekiq.yml format
- [ ] Data API (`Sidekiq::Stats`, `Queue`, `JobRecord`, `RetrySet`, `ScheduledSet`, `DeadSet`, `ProcessSet`, `WorkSet`)
- [ ] Web UI routes (table in §25.4)
- [ ] Lifecycle events + handlers (`error_handlers`, `death_handlers`, `on(:startup/...)`)
- [ ] Testing API (`Sidekiq.testing!`, `Sidekiq::Job.{jobs,clear,drain,perform_one}`, `Sidekiq::Queues`)
- [ ] ActiveJob unwrap support in API
- [ ] Iterable job state in `it-<jid>` HASH with TTL

---

## 34. References

- Sidekiq repo: https://github.com/sidekiq/sidekiq
- Wiki: https://github.com/sidekiq/sidekiq/wiki
- Key files in `lib/sidekiq/`:
  - `sidekiq.rb`, `config.rb`, `capsule.rb`, `client.rb`, `job.rb`, `api.rb`
  - `launcher.rb`, `manager.rb`, `processor.rb`, `fetch.rb`, `scheduled.rb`
  - `job_retry.rb`, `job_logger.rb`, `job_util.rb`, `component.rb`
  - `middleware/chain.rb`, `middleware/modules.rb`
  - `web.rb`, `web/application.rb`, `web/router.rb`, `web/action.rb`, `web/helpers.rb`, `web/config.rb`
  - `metrics/query.rb`, `metrics/tracking.rb`
  - `iterable_job.rb`, `job/iterable.rb`, `job/interrupt_handler.rb`
  - `cli.rb`, `embedded.rb`, `deploy.rb`, `test_api.rb`, `transaction_aware_client.rb`
