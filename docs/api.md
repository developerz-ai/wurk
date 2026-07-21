# Data API

The Data API is how you inspect and manipulate queues and jobs **from your own
code** — a Rails console, a rake task, an admin controller, a health check.
The server never uses it; it reads and writes the same Redis structures the
server does.

Everything here loads with the gem:

```ruby
require "wurk"     # or: require "sidekiq" / require "sidekiq/api"
```

There is no separate `sidekiq/api` load step — `lib/sidekiq/api.rb` is a
one-line passthrough to `wurk`, so an app that already calls
`require "sidekiq/api"` keeps working unchanged.

Every class below is exposed under its `Sidekiq::*` name by
`lib/wurk/compat.rb`. These are **the same object**, not a wrapper:

```ruby
Sidekiq::Queue.equal?(Wurk::Queue)   # => true
Sidekiq::Stats.equal?(Wurk::Stats)   # => true
```

| Sidekiq name | Wurk class |
|---|---|
| `Sidekiq::Stats` | `Wurk::Stats` |
| `Sidekiq::Queue` | `Wurk::Queue` |
| `Sidekiq::JobRecord` | `Wurk::JobRecord` |
| `Sidekiq::SortedEntry` | `Wurk::SortedEntry` |
| `Sidekiq::ScheduledSet` | `Wurk::ScheduledSet` |
| `Sidekiq::RetrySet` | `Wurk::RetrySet` |
| `Sidekiq::DeadSet` | `Wurk::DeadSet` |
| `Sidekiq::ProcessSet` / `Sidekiq::Process` | `Wurk::ProcessSet` / `Wurk::Process` |
| `Sidekiq::WorkSet` (`Sidekiq::Workers`) / `Sidekiq::Work` | `Wurk::WorkSet` (`Wurk::Workers`) / `Wurk::Work` |
| `Sidekiq::Deploy` | `Wurk::Deploy` |
| `Sidekiq::Web` (so `Sidekiq::Web::Search`) | `Wurk::Web` |

`Wurk::SortedSet` and `Wurk::JobSet` have **no** `Sidekiq::*` alias — see
[§ Divergences](#divergences-from-the-sidekiq-spec).

Examples use the `Wurk::` names throughout; substitute `Sidekiq::` freely.

---

## `Wurk::Stats`

Cluster-wide counters. The cheap ones are fetched in **one pipeline at
construction time**, so a single instance answers many questions without
re-querying Redis — build one, read many fields, throw it away.

```ruby
stats = Wurk::Stats.new
stats.processed      # => 129_402
stats.failed         # => 17
stats.retry_size     # => 3
```

| Method | Returns | Notes |
|---|---|---|
| `processed` | `Integer` | `GET stat:processed`, snapshotted at `new` |
| `failed` | `Integer` | `GET stat:failed`, snapshotted at `new` |
| `expired` | `Integer` | jobs dropped by `expires_in`, snapshotted at `new` |
| `scheduled_size` | `Integer` | `ZCARD schedule` |
| `retry_size` | `Integer` | `ZCARD retry` |
| `dead_size` | `Integer` | `ZCARD dead` |
| `processes_size` | `Integer` | `SCARD processes` |
| `enqueued` | `Integer` | sum of `LLEN` over every known queue — **re-queries**, linear in queue count |
| `workers_size` | `Integer` | sum of the `busy` field over every process — **re-queries**, linear in process count |
| `queues` | `Hash{String=>Integer}` | queue name → depth, **largest first** |
| `queue_summaries` | `Array<QueueSummary>` | name/size/latency/paused per queue, largest first |
| `default_queue_latency` | `Float` | seconds the oldest `default` job has waited |
| `reset(*stats)` | pipeline result | `SET`s counters to `0` (not `DEL`, so reads stay `Integer`) |

`reset` with no arguments clears `processed`, `failed`, **and** `expired`.
With arguments it clears only the named subset; anything outside those three
names is ignored.

```ruby
Wurk::Stats.new.reset("failed")
Wurk::Stats.new.reset(%w[processed failed])
```

`QueueSummary` is a `Data` class — `name`, `size`, `latency`, `paused`, plus a
`paused?` alias. Destructuring is part of the contract; third-party gems rely
on it.

```ruby
Wurk::Stats.new.queue_summaries.each do |q|
  puts "#{q.name}: #{q.size} jobs, #{q.latency.round(1)}s behind#{' (paused)' if q.paused?}"
end
```

The three re-querying readers (`enqueued`, `workers_size`, and the two queue
breakdowns) hit Redis on **every** call. Assign them to a local if you need the
value twice.

---

## `Wurk::Stats::History`

Per-day counters written by the server as `stat:<name>:YYYY-MM-DD` strings.
Missing days come back as `0` rather than being omitted.

```ruby
history = Wurk::Stats::History.new(30)            # last 30 days, ending today
history.processed  # => {"2026-07-20" => 41_233, "2026-07-19" => 39_887, …}
history.failed
history.expired
```

| Method | Returns |
|---|---|
| `new(days_previous, start_date = nil, pool: nil)` | raises `ArgumentError` unless `days_previous` is in `1..1825` |
| `processed` | `Hash{String=>Integer}` keyed `YYYY-MM-DD` |
| `failed` | same shape |
| `expired` | same shape |

`start_date` defaults to `Date.today`; keys run backwards from it. `pool:`
targets a non-default connection pool (a second Redis shard, say); omitted, it
uses `Wurk.redis`.

Don't confuse this with `Wurk::History` (aliased `Sidekiq::History`), which is
the metrics-recording server middleware, not a reader.

---

## `Wurk::Queue`

One named queue: the `queue:<name>` LIST, plus membership in the `queues` SET.
`Enumerable`.

```ruby
q = Wurk::Queue.new("critical")
q.size        # => 4_291
q.latency     # => 12.4
q.paused?     # => false
```

| Method | Returns | Notes |
|---|---|---|
| `Queue.all` | `Array<Queue>` | every known queue, sorted by name |
| `new(name = "default")` | `Queue` | |
| `name` (alias `id`) | `String` | |
| `size` | `Integer` | `LLEN` — O(1) |
| `latency` | `Float` | seconds since the oldest job (list tail) was enqueued; `0.0` when empty |
| `each { \|JobRecord\| … }` | | paged `LRANGE`, 50 per page |
| `find_job(jid)` | `JobRecord` or `nil` | O(n) full scan — prefer `delete_job` if you only want to remove it |
| `clear` | `true` | `UNLINK` the list + `SREM` from the `queues` set |
| `as_json` | `{name: …}` | |
| `paused?` | `Boolean` | membership in the `paused` SET |
| `pause!` | `true` | `SADD paused` — idempotent |
| `unpause!` | `true` | `SREM paused` — idempotent |
| `delete_job(jid)` | `Integer` | Lua; see [§ Fast Lua API](#fast-lua-api) |
| `delete_by_class(klass)` | `Integer` | Lua; see [§ Fast Lua API](#fast-lua-api) |

### Pausing a queue

Pause/unpause is a Sidekiq **Pro** feature; Wurk ships it free, with the same
Redis structure (a SET named `paused`) and the same method names, so Pro code
drops in.

```ruby
Wurk::Queue.new("bulk_export").pause!
# … deploy a fix, drain a dependency, whatever …
Wurk::Queue.new("bulk_export").unpause!
```

- Fetchers consult the same `paused` SET, so pausing takes effect cluster-wide
  without a restart or a signal.
- **Only new fetches stop.** Jobs already running continue to completion.
- Enqueueing is unaffected — the queue keeps growing while paused.
- Both calls are idempotent and return `true` whether or not they changed
  anything.

### Enumerating

```ruby
Wurk::Queue.new("default").each do |job|
  puts "#{job.jid} #{job.display_class} #{job.args.inspect}"
end
```

Iteration is a snapshot-free paged `LRANGE`: jobs pushed or popped while you
iterate can be seen twice or missed. That's inherent to walking a live LIST —
treat the output as advisory, not as a transaction.

---

## `Wurk::JobRecord`

One job payload, as yielded by `Queue#each`. Wraps the raw JSON string and
parses it **lazily**, so scanning a large queue costs no JSON work for jobs you
never inspect.

| Method | Returns |
|---|---|
| `item` | `Hash` — the parsed payload (memoized) |
| `value` | `String` — the exact JSON bytes stored in Redis |
| `queue` | `String` or `nil` — the queue this record came from |
| `klass` | `String` — `item["class"]` |
| `args` | `Array` |
| `jid` | `String` |
| `bid` | `String` or `nil` — owning batch id |
| `tags` | `Array` — `[]` when absent |
| `enqueued_at` / `created_at` / `failed_at` / `retried_at` | `Time` or `nil` |
| `latency` | `Float` — seconds since `enqueued_at`; `0.0` if missing or clock-skewed into the future |
| `error_backtrace` | `Array<String>` or `nil` — decoded from base64 + zlib; `nil` on corruption |
| `[](name)` | any — raw payload field, for anything not listed above |
| `iterable_state` | iterable-job progress, or `nil` for a non-iterable job |
| `display_class` | `String` — unwraps ActiveJob / ActionMailer wrappers |
| `display_args` | `Array` — same unwrapping, with encrypted args masked as `"<encrypted>"` |
| `delete` | `Boolean` — `LREM queue:<q> 1 value`; `true` when ≥1 entry went away |

`display_class` / `display_args` are **UI-facing**: they unwrap
`ActiveJob::QueueAdapters::*::JobWrapper` payloads to the real job class, and
render `ActionMailer` deliveries as `MailerClass#method`. For programmatic
decisions use `klass` and `args`, which are the payload verbatim.

`delete` matches on exact bytes, which is why `value` exists — never
re-serialize a payload and expect `LREM` to find it.

```ruby
q = Wurk::Queue.new("default")
q.select { |job| job.klass == "LegacyJob" }.each(&:delete)
```

Both timestamp shapes Sidekiq has historically written (float epoch seconds,
integer epoch milliseconds) are handled by the `*_at` readers and by `latency`.

---

## Sorted sets — scheduled, retry, dead

Three ZSETs, all scored by epoch seconds: `schedule` (when the job should
run), `retry` (when the next attempt is due), `dead` (when it was killed).

```ruby
Wurk::ScheduledSet.new
Wurk::RetrySet.new
Wurk::DeadSet.new
```

Each takes an optional key name (`RetrySet.new("retry")`) — that exists for
tests operating on a namespaced ZSET. Production callers use the default.

### `Wurk::SortedSet` — the generic ZSET surface

| Method | Returns | Notes |
|---|---|---|
| `name` | `String` | the Redis key |
| `size` | `Integer` | `ZCARD` — O(1) |
| `scan(match, count = 100)` | enumerator, or yields | `ZSCAN` with the match wrapped in `*…*` |
| `clear` | `true` | `UNLINK` the whole key |
| `as_json` | `{name: …}` | |

### `Wurk::JobSet` — the job-aware surface

| Method | Returns | Notes |
|---|---|---|
| `each { \|SortedEntry\| … }` | `Integer` (rows yielded) | paged `ZRANGE … REV`, 50 per page — **newest/furthest-out first** |
| `schedule(timestamp, message)` | `ZADD` result | adds a payload at a score |
| `fetch(score, jid = nil)` | `Array<SortedEntry>` | `score` is `Time`, `Numeric`, or a `Range`; anything else raises `ArgumentError` |
| `find_job(jid)` | `SortedEntry` or `nil` | `ZSCAN`-based, O(n) |
| `retry_all` | `Integer` | re-enqueues every entry |
| `kill_all(notify_failure: true, ex: nil)` | `Integer` | moves every entry to the dead set |
| `pop_each { \|json, score\| … }` | | `ZPOPMIN` loop until empty — destructive |
| `remove_job(entry)` | `Boolean` | exact-value `ZREM`, falling back to a (score, jid) scan |
| `delete_by_value(name, value)` | `Boolean` | `ZREM` by exact bytes |
| `delete_by_jid(score, jid)` (alias `delete`) | `Boolean` | scans the score bracket, then `ZREM`s |

`fetch` is the cheap lookup — if you kept the score (e.g. from a
`SortedEntry#id`, `"<score>|<jid>"`), use it instead of `find_job`:

```ruby
score, jid = entry_id.split("|")
entry = Wurk::RetrySet.new.fetch(score.to_f, jid).first
```

`retry_all` and `kill_all` loop until the set is empty and are **not
transactional** — an exception part-way through leaves the set partly drained.
For large sets, iterate in bounded chunks yourself.

### `Wurk::DeadSet` extras

| Method | Returns | Notes |
|---|---|---|
| `kill(message, opts = {})` | `true` | `ZADD` + trim + death handlers |
| `kill_raw(payload, max_jobs:, timeout:)` | `true` | `ZADD` + trim, **no** death handlers |
| `trim(max_jobs:, timeout:)` | `true` | `ZREMRANGEBYSCORE` (age) + `ZREMRANGEBYRANK` (count) |
| `API_KILL_MESSAGE` | `"Job killed by API"` | the synthesized exception message for kills with no real error |

`kill` takes the raw JSON payload string and an options hash:

| Option | Default | Effect |
|---|---|---|
| `:notify_failure` | `true` | run the configured death handlers |
| `:trim` | `true` | apply the two-axis trim after adding |
| `:ex` | synthesized `RuntimeError` carrying `API_KILL_MESSAGE` | exception handed to death handlers |
| `:max_jobs` / `:timeout` | `dead_max_jobs` / `dead_timeout_in_seconds` config | per-call trim overrides |

Trim runs on every kill, so the morgue stays bounded on both axes without a
separate sweeper.

---

## `Wurk::SortedEntry`

One member of a sorted set. Subclasses `JobRecord`, so every attribute above is
available, plus the score and the set-specific mutations.

| Method | Returns | Notes |
|---|---|---|
| `score` | `Float` | epoch seconds |
| `parent` | `JobSet` | the owning set |
| `id` | `String` | `"<score>\|<jid>"` — the wire-compat identifier dashboards use |
| `at` | `Time` | `score` as UTC |
| `error?` | `Boolean` | true when the payload carries an `error_class` |
| `delete` | `Boolean` | removes this entry from its set |
| `reschedule(at)` | `ZINCRBY` result | shifts the score to `at` (sent as a delta, so caller/Redis clock skew doesn't matter) |
| `add_to_queue` | payload `Hash` or `nil` | removes + re-enqueues, payload untouched |
| `retry` | payload `Hash` or `nil` | removes + re-enqueues, **decrementing `retry_count`** so a manual retry doesn't burn an attempt |
| `kill` | payload `Hash` or `nil` | removes + writes to the dead set, firing death handlers |

```ruby
Wurk::RetrySet.new.each do |entry|
  entry.kill if entry["error_class"] == "ActiveRecord::RecordNotFound"
end
```

The three mutations return `nil` **without acting** when removal from the
parent set fails — that's how a concurrent retry from the dashboard can't
cause the same job to be pushed twice.

`reschedule` takes the absolute target time:

```ruby
entry = Wurk::ScheduledSet.new.find_job(jid)
entry.reschedule(Time.now + 3600)
```

Note that on entries produced by `each` / `scan` (built from raw JSON),
`#queue` is `nil` — read `entry["queue"]` instead.

---

## `Wurk::ProcessSet` and `Wurk::Process`

Live cluster topology: the `processes` SET plus one heartbeat HASH per
identity.

```ruby
ps = Wurk::ProcessSet.new
ps.total_concurrency   # => 50
ps.total_rss_in_kb     # => 1_842_912
```

| Method | Returns | Notes |
|---|---|---|
| `new(clean_plz = true)` | `ProcessSet` | runs `cleanup` unless you pass `false` |
| `ProcessSet[identity]` | `Process` or `nil` | `nil` for an unknown **or** lapsed identity |
| `each { \|Process\| … }` | | pipelined `HMGET`, sorted by identity; skips lapsed heartbeats |
| `size` | `Integer` | raw `SCARD` — **not** pruned, may over-count |
| `cleanup` | `Integer` | `SREM`s identities whose heartbeat expired; globally rate-limited to 1/min |
| `total_concurrency` | `Integer` | sum over live processes |
| `total_rss_in_kb` (alias `total_rss`) | `Integer` | sum over live processes |
| `leader` | `String` | `GET dear-leader`; `""` when unset |

`size` counts SET members; heartbeat hashes expire after 60s, so a crashed
process lingers in the count until a `cleanup`. For an accurate number use
`each.count` (or just `count`, since `ProcessSet` is `Enumerable`).

Passing `clean_plz = false` skips the prune — do that on a hot path or when
taking repeated snapshots.

### `Wurk::Process`

| Method | Returns | Notes |
|---|---|---|
| `identity` (alias `id`) | `String` | `<hostname>:<pid>:<nonce>` |
| `[](key)` | any | raw heartbeat/info field (`"busy"`, `"beat"`, `"rss"`, `"rtt_us"`, …) |
| `tag` / `labels` / `version` | `String` / `Array` / `String` | |
| `queues` | `Array<String>` | derived from `capsules`, falling back to the legacy `queues` field |
| `weights` | `Hash` | same fallback; two capsules on one queue name collapse |
| `capsules` | `Hash` or `nil` | |
| `embedded?` | `Boolean` | |
| `stopping?` | `Boolean` | true once the process has accepted a TSTP |
| `leader?` | `Boolean` | compares `identity` against `dear-leader` |
| `quiet!` | | `LPUSH <identity>-signals "TSTP"` |
| `stop!` | | `LPUSH <identity>-signals "TERM"` |
| `dump_threads` | | `LPUSH <identity>-signals "TTIN"` |

The three signal methods are **asynchronous**: they leave a message in a
60-second-TTL list that the target process picks up on its next heartbeat, so
allow up to ~10 seconds for the effect. `quiet!` and `stop!` raise on an
embedded process (there's no separate process to signal).

```ruby
Wurk::ProcessSet.new.each do |process|
  process.quiet! if process["rss"].to_i > 2_000_000 && !process.embedded?
end
```

---

## `Wurk::WorkSet` and `Wurk::Work`

What is executing **right now**, across the cluster. Reads one
`<identity>:work` HASH per registered process, so it lags reality by up to one
heartbeat (10s).

| Method | Returns | Notes |
|---|---|---|
| `each { \|process_id, thread_id, Work\| … }` | | pipelined `HGETALL`, sorted by `run_at` — oldest in-flight job first |
| `size` | `Integer` | sum of the `busy` field across processes |
| `find_work(jid)` (alias `find_work_by_jid`) | `Work` or `nil` | O(n) — for a human at a console, not for app logic |

`Wurk::Workers` is a deprecated alias of `WorkSet` for gems written against
Sidekiq < 8.

### `Wurk::Work`

| Method | Returns |
|---|---|
| `process_id` / `thread_id` | `String` |
| `queue` | `String` |
| `payload` | `String` — raw JSON being executed |
| `run_at` | `Time` |
| `job` | `JobRecord` — lazily wrapped `payload` |

```ruby
Wurk::WorkSet.new.each do |pid, tid, work|
  age = Time.now - work.run_at
  warn "#{work.job.display_class} on #{pid}/#{tid} running #{age.round}s" if age > 300
end
```

---

## Fast Lua API

Sidekiq Pro replaces the O(n)-round-trip Ruby loops with server-side Lua.
Wurk ships the same surface free, mixed into `Queue` and `SortedSet` at load
time — there is nothing to require or enable.

| Method | Returns | Notes |
|---|---|---|
| `Queue#delete_job(jid)` | `Integer` | payloads removed; `ArgumentError` on a blank jid |
| `Queue#delete_by_class(klass)` | `Integer` | accepts a `Class`, `String`, or `Symbol`; `ArgumentError` on a blank name |
| `SortedSet#scan(match) { \|SortedEntry\| … }` | | one-argument block form |
| `SortedSet#scan(match) { \|value, score\| … }` | | two-argument block form — the raw pairs |

```ruby
Wurk::Queue.new("default").delete_job(jid)         # one round trip
Wurk::Queue.new("default").delete_by_class(MyJob)  # one round trip

Wurk::RetrySet.new.scan("NoMethodError") { |entry| entry.delete }
Wurk::DeadSet.new.scan("CustomerJob")    { |entry| entry.retry }
```

Which form `scan` yields is decided by **block arity**: a one-parameter block
gets a `SortedEntry` (so you can call `delete` / `retry` / `kill` without
re-parsing JSON); a two-parameter block gets `(value, score)` as the base
`ZSCAN` surface does. With no block, `scan` returns an enumerator over the raw
pairs.

**Prefer the Lua paths on large sets.** `Queue#find_job(jid).delete` walks the
list 50 payloads at a time over the network, parses JSON per candidate, then
issues an `LREM` — on a million-entry queue that's ~20 000 round trips.
`delete_job` is a single `EVALSHA`; the scan happens inside Redis, no payload
crosses the wire. The trade is that the Lua script blocks Redis for the
duration of its `LRANGE` — acceptable for an admin action, not for a loop.

The scripts are `SCRIPT LOAD`ed once per pool and invoked by `EVALSHA`
thereafter. `delete_job` matches on the literal `"jid":"<jid>"` substring and
`delete_by_class` on `"class":"<name>"`, without parsing JSON, so partial
corruption elsewhere in a payload can't break the sweep.

---

## Dashboard search

`Wurk::Web::Search` (also reachable as `Sidekiq::Web::Search`) is the
substring search behind the dashboard's search box, and it has a plain Ruby
entry point. It covers queues **and** the three sorted sets — Sidekiq Pro's
version covers only the sorted sets.

```ruby
search = Wurk::Web::Search.new("NoMethodError", kinds: %w[retry dead], limit: 50)
rows = search.to_a
search.truncated?   # => true if a scan bound stopped it early
```

| Method / constant | Returns | Notes |
|---|---|---|
| `new(substring, kinds: KINDS, limit: 100)` | `Search` | unknown kinds are dropped; an empty selection means all kinds |
| `each { \|Hash\| … }` | enumerator without a block | stops at `limit` |
| `to_a` | `Array<Hash>` | |
| `truncated?` | `Boolean` | meaningful only after the scan has run |
| `substring` / `kinds` / `limit` | | the normalized inputs |
| `KINDS` | `%w[queues retry scheduled dead]` | |
| `DEFAULT_LIMIT` / `MAX_LIMIT` | `100` / `500` | `limit` is clamped into `1..500` |

Each row is a `Hash` with `:kind`, `:name` (queue or set name), `:jid`,
`:klass`, `:args`, `:queue`, `:enqueued_at`, `:created_at`; sorted-set rows
also carry `:score`, `:at`, `:error_class`, `:error_message`, `:retry_count`.
An empty substring yields nothing.

Search is **deliberately bounded** so a keystroke can't full-walk a
multi-million-entry store: at most 5 000 elements per queue and 20 000 per
request across all stores. When a bound stops the scan with elements
unexamined, `truncated?` flips to `true` and the results are partial. If you
need exhaustive matching, iterate the set yourself and accept the cost.

---

## `Wurk::Deploy`

Records a deploy marker so throughput charts can be read against releases.

```ruby
Wurk::Deploy.mark!                        # label = `git log -1 --format="%h %s"`
Wurk::Deploy.mark!("v2.14.0 hotfix")      # explicit label
Wurk::Deploy.new.mark!(label: "v2.14.0", at: Time.now)
```

| Method | Returns | Notes |
|---|---|---|
| `Deploy.mark!(label = nil, at: Time.now, **opts)` | `String` (iso8601) or `nil` | positional label matches Sidekiq; `label:` keyword also accepted, positional wins |
| `#mark!(label: nil, at: Time.now)` | `String` (iso8601) or `nil` | `nil` when the label is blank or the dedupe lock was already held |
| `#fetch(date = Time.now.utc)` | `Hash{String=>String}` | `{iso8601 => label}` for that day |
| `new(pool: nil)` | `Deploy` | `pool:` targets a non-default Redis |

What it writes:

| Key | Type | Contents |
|---|---|---|
| `<YYYYMMDD>-marks` | HASH | field = iso8601 timestamp rounded down to the minute, value = label; TTL 90 days |
| `deploylock-<label>` | STRING | `SET NX EX 60` dedupe lock |

The lock is why a fleet-wide deploy where every booting process calls `mark!`
produces **one** row, not N: the first writer wins for 60 seconds and everyone
else gets `nil` back. The default label shells out to `git`; if that fails, the
label resolves to `nil` and nothing is written.

Marks are read back only through `Deploy#fetch` — Wurk writes and exposes
them, but nothing else in the gem consumes them today.

---

## Leader election

Wurk elects one leader per cluster via a `SET NX EX` lock at `dear-leader`
(TTL 30s, renewed every 15s, followers recheck every 60s). Wurk's own
leader-gated work — the metrics rollups, the queue-depth sampler, history
retention, cron polling — rides on it, and your code can too.

Best-effort, **not Raft**: during a partition a stale leader can briefly
co-exist with a new one until the TTL lapses. Anything that must not
double-execute needs its own idempotency guard.

### The public predicate

`leader?` from `Wurk::Component` (aliased `Sidekiq::Component`) is the
supported way to ask "am I the one?".

```ruby
class NightlyReconciler
  include Sidekiq::Component

  def initialize(config) = @config = config

  def start
    @thread = safe_thread("reconciler") do
      loop do
        run_reconciliation if leader?
        sleep 60
      end
    end
  end
end
```

`leader?` is cached for ~5 seconds per component instance so a tight loop
doesn't double its Redis traffic, returns `false` unconditionally when the
process opted out, and swallows Redis errors into `false` — a partition can't
surface as an exception in your loop.

### The lifecycle event

```ruby
Wurk.configure_server do |config|
  config.on(:leader) do
    # this process just gained leadership
  end
end
```

Fires on each follower → leader transition. There is no `:follower` event;
long-running threads poll `leader?`.

### Opting a process out

`WURK_LEADER=false` (or `SIDEKIQ_LEADER=false`) makes a process never
campaign: `acquire` no-ops, `leader?` is permanently `false`, and the renewal
thread refuses to start. Use it for hot-standby pools.

### `Wurk::Leader` directly

The launcher runs one instance per process, so you rarely construct your own.
For a standalone coordinator outside the server, the surface is:

| Method | Returns | Notes |
|---|---|---|
| `Leader.opted_out?` | `Boolean` | reads `WURK_LEADER` / `SIDEKIQ_LEADER` |
| `new(config:, key:, ttl:, renew_interval:, follower_interval:, pool:, owner:)` | `Leader` | defaults: key `dear-leader`, ttl 30, renew 15, follower 60 |
| `acquire` | `Boolean` | `SET NX EX`, or `EXPIRE` when we already own the key |
| `release` | `nil` | compare-and-delete — won't yank leadership from a successor |
| `leader?` | `Boolean` | last known state |
| `start` | `Thread` or `nil` | idempotent; `nil` when opted out |
| `stop` | | signals, joins, releases |
| `running?` | `Boolean` | |
| `token` | `Integer` or `nil` | monotonic fencing token, bumped on each *gain* |
| `key` / `ttl` / `owner` / `config` | | as configured; `owner` defaults to this process's identity |

`token` is a small addition over Sidekiq Enterprise, which deliberately
exposes no fencing. It's `INCR`ed on every follower → leader transition, so a
newer leader's token is strictly greater than every prior leader's — enough to
reject a stale writer, if your storage can compare it. It is best-effort like
everything else here: it is not re-read on renewals, only on transitions.

---

## Performance notes

The Data API talks to Redis on nearly every call. The failure modes are all
variations on "an O(n) loop that looked O(1)".

**Don't full-enumerate a large set.** `Queue#each` and `JobSet#each` page 50 at
a time; `find_job` walks until it matches. On a set with millions of entries
that's tens of thousands of round trips and a lot of GC pressure from parsed
payloads. Reach for `Queue#delete_job` / `#delete_by_class`, `JobSet#fetch`
(when you know the score), or `SortedSet#scan` instead.

**Know which readers re-query.** `Stats` snapshots seven counters in one
pipeline at construction — reuse the instance. But `enqueued`, `workers_size`,
`queues`, and `queue_summaries` hit Redis every call, and the first two are
linear in queue and process count. Never put them in a request path or a tight
loop.

**Don't hold a connection across a long loop.** Every method here checks a
connection out of a fixed-size pool for the duration of its own call and gives
it straight back — that's why paging is per-page rather than one long
enumeration. If you wrap your own iteration in `Wurk.redis { … }`, you pin one
connection for the whole loop while the calls inside it try to check out
another; on a small pool that's contention at best. Let each call manage its
own checkout, and do slow work (HTTP, database writes) outside any
`Wurk.redis` block.

**`ProcessSet.new` prunes by default.** Construction runs `cleanup`, which is
globally rate-limited to once a minute but still costs an `SMEMBERS` plus a
pipelined `HGET` per identity. Repeated snapshot reads should pass
`ProcessSet.new(false)`.

**`retry_all` / `kill_all` are unbounded and non-transactional.** They loop
until the set is empty, one job at a time, firing death handlers per entry for
`kill_all`. On a large dead set, chunk it yourself and expect it to take a
while.

**Live data is lagged and racy.** `WorkSet` reflects the last heartbeat (up to
10s stale). `ProcessSet#size` over-counts crashed processes until a cleanup.
Queue enumeration is a moving target. Design around eventual consistency; don't
assert on exact counts.

---

## Divergences from the Sidekiq spec

Wurk implements the Data API to `docs/target/sidekiq-{free,pro,ent}.md`. The
deliberate differences:

| Area | Sidekiq | Wurk |
|---|---|---|
| `Queue#paused?` | always `false` in OSS; pause is a Pro feature | fully implemented, free — `pause!` / `unpause!` / `paused?`, with fetchers honoring the `paused` SET |
| Fast Lua API | Pro only | included, loaded by default |
| Search | Pro; sorted sets only | free, and extended to cover queue LISTs, with explicit scan bounds and `truncated?` |
| `Stats#expired` and `Stats::History#expired` | not in the OSS spec | present — Wurk tracks `expires_in` drops as a first-class counter |
| `Stats#reset` default | `["processed", "failed"]` | also clears `expired` |
| `JobSet#kill_all` | `notify_failure: false` default | `notify_failure: true` default, matching the per-entry `each(&:kill)` behavior so death handlers observe API kills |
| `Queue#💣` / `SortedSet#💣` alias for `clear` | present | **not implemented** — use `clear` |
| `Sidekiq::SortedSet` / `Sidekiq::JobSet` aliases | present | **not aliased** — the concrete sets (`Sidekiq::RetrySet`, …) are; reference `Wurk::SortedSet` / `Wurk::JobSet` for the base classes |
| Leader fencing | none exposed, by design | `Wurk::Leader#token`, a best-effort monotonic fencing token |
| `SortedEntry#queue` | — | `nil` on entries built from raw JSON (i.e. everything from `each` / `scan`); read `entry["queue"]` |

---

## Related

- [Dashboard](dashboard.md) — the UI over the same data, and extension routes.
- [Authentication & authorization](authentication.md) — why you should drive
  Wurk through this API rather than scripting the dashboard's JSON endpoints.
- [Metrics history](metrics-history.md) — the time-series data behind the
  charts.
- [Migrating from Sidekiq](migrate-from-sidekiq.md) — the full alias contract.
