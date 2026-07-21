# Iterable jobs

A job that walks a million records is a job that cannot survive a deploy. Your
process gets a `TERM`, the shutdown timeout expires, the thread is killed, and
the work restarts from record zero on the next boot — or worse, gets retried
from zero and re-sends 400,000 emails.

An **iterable job** inverts that. You don't write a loop; you hand Wurk an
enumerator that yields `[item, cursor]` pairs and a method that processes one
item. Wurk drives the loop, checkpoints the cursor into Redis, and — when the
job is interrupted — resumes from the last checkpoint on the next run.

```ruby
# app/jobs/backfill_job.rb
class BackfillJob
  include Wurk::IterableJob

  def build_enumerator(cursor:)
    active_record_records_enumerator(User.where(migrated: false), cursor: cursor)
  end

  def each_iteration(user)
    user.migrate!
  end
end

BackfillJob.perform_async
```

Reach for one when the work is **long** (minutes to hours), **chunkable** into
independent units, and each unit is **idempotent**. If the job finishes in a
few seconds, a plain `Wurk::Job` is simpler and cheaper — iterable jobs pay a
Redis write every five seconds for their durability.

`Sidekiq::IterableJob` is an alias for `Wurk::IterableJob`, and the enumerator
classes resolve under their upstream names too — see
[§ Sidekiq compatibility](#sidekiq-compatibility).

---

## 1. The contract

`include Wurk::IterableJob` also includes `Wurk::Job`, so you get the whole
worker DSL (`sidekiq_options`, `perform_async`, `perform_in`, `set`, `jid`,
`logger`) for free. You do **not** `include Wurk::Job` separately.

You must override two methods:

| Method | Signature | Must return / do |
|---|---|---|
| `build_enumerator` | `build_enumerator(*args, cursor:)` | An `Enumerator` yielding `[item, new_cursor]` pairs |
| `each_iteration` | `each_iteration(item, *args)` | Process exactly one item |

`*args` in both is the job's `perform_async` arguments. The base
implementations raise `NotImplementedError`, so a class that forgets either one
fails on its first run, not silently.

**You cannot define `#perform`.** The module owns the run loop, and a
`method_added` guard raises `ArgumentError` at class-definition time:

```ruby
class BadJob
  include Wurk::IterableJob

  def perform(*) = nil   # => ArgumentError: BadJob is an IterableJob;
end                      #    override #each_iteration instead of #perform
```

The guard is installed by `include`, so it only sees methods defined *after*
that line. Put the `include` first.

The cursor you yield must **round-trip through JSON** — it is stored with
`JSON.generate` and reloaded with `JSON.parse`. Integers, strings, arrays and
plain hashes are fine; symbol keys come back as strings, and objects with a
custom `to_json` come back as whatever that produced.

---

## 2. Built-in enumerator builders

Instance methods available inside `#build_enumerator`. All take `cursor:` and
thread it into the underlying API, so resumption is real, not a re-scan-and-skip
(except where noted).

| Builder | Yields | Cursor is |
|---|---|---|
| `array_enumerator(array, cursor:)` | `[item, index]` | integer index |
| `csv_enumerator(csv, cursor:)` | `[row, index]` | integer row index |
| `csv_batches_enumerator(csv, cursor:, batch_size: 100)` | `[rows_batch, index]` | integer batch index |
| `active_record_records_enumerator(relation, cursor:, **opts)` | `[record, record.id]` | primary key |
| `active_record_batches_enumerator(relation, cursor:, **opts)` | `[batch, batch.first.id]` | primary key of batch head |
| `active_record_relations_enumerator(relation, cursor:, **opts)` | `[relation, relation.first.id]` | primary key of batch head |

### Arrays

```ruby
def build_enumerator(*args, cursor:)
  array_enumerator(%w[a b c d], cursor: cursor)
end
```

Raises `ArgumentError` unless you pass an actual `Array`. The array is
materialized and `drop(cursor)`-ed eagerly — fine for a few thousand entries,
wrong for a million-row export.

### CSV

Requires the host app to have `require "csv"`; Wurk does not force the
dependency. `csv_enumerator` raises `ArgumentError` unless the argument is a
`CSV` instance (a `String` of CSV text is not accepted).

```ruby
def build_enumerator(path, cursor:)
  csv_batches_enumerator(CSV.open(path, headers: true), cursor: cursor, batch_size: 500)
end

def each_iteration(rows, _path)
  Contact.insert_all(rows.map(&:to_h))
end
```

The enumerator's lazy `#size` shells out to `wc -l` on `csv.path` (minus one
when `headers` is set) and returns `nil` for a `CSV` with no file behind it.
The run loop never calls `#size`; it exists for progress display.

### ActiveRecord

ActiveRecord is **not** a Wurk dependency. These builders just call the
relation's own batching API (`find_each`, `find_in_batches`, `in_batches`) with
`start: cursor`, so they work whenever the host app has AR loaded and raise a
plain `NoMethodError` otherwise.

`**opts` passes straight through to the underlying AR method — `batch_size:`,
`order:`, `finish:`, and so on. For `active_record_relations_enumerator`,
`batch_size:` is normalized to `in_batches`' `of:` keyword so one option name
works across all three builders; passing both `of:` and `batch_size:` lets
`of:` win instead of raising.

```ruby
def build_enumerator(*, cursor:)
  active_record_relations_enumerator(Order.pending, cursor: cursor, batch_size: 5_000)
end

def each_iteration(relation)
  relation.update_all(status: "expired")
end
```

You are not limited to the builders — any `Enumerator` yielding `[item, cursor]`
pairs works, including one you write by hand.

---

## 3. The cursor: what is persisted, and where

State lives in a Redis HASH keyed `it-<jid>` — the same key and field names
Sidekiq uses, so the data is wire-compatible both directions.

| Field | Type | Meaning |
|---|---|---|
| `ex` | integer | execution count — how many times this jid has started |
| `c` | JSON string | the last checkpointed cursor |
| `rt` | float | accumulated runtime in seconds across all executions |
| `cancelled` | integer | epoch seconds, present only once cancelled |

| Constant | Value | Role |
|---|---|---|
| `STATE_TTL` | 30 days | HASH expiry, refreshed on every checkpoint |
| `STATE_FLUSH_INTERVAL` | 5 seconds | cursor flush cadence **and** cancellation poll cadence |
| `CANCELLATION_PERIOD` | 3 days | shorter TTL applied once `cancelled` is written |

The loop is:

1. `perform` resets in-process state, then `HGETALL it-<jid>`.
2. If `ex > 0`, `on_resume` fires; otherwise `on_start`. `ex` is then incremented.
3. `build_enumerator(*args, cursor: <loaded cursor or nil>)`.
4. For each yielded pair: check cancellation → run `around_iteration { each_iteration(item, *args) }` → store the new cursor in memory → flush to Redis if `STATE_FLUSH_INTERVAL` has elapsed since the last flush.
5. On normal completion: final flush, `on_complete`, then `DEL it-<jid>`.

Two consequences worth internalizing:

- **The cursor is flushed on a timer, not per item.** A job killed mid-run
  resumes from a cursor that may be up to five seconds stale. Items between the
  checkpoint and the kill are replayed.
- **State is deleted on success.** A completed job has no `it-<jid>` key, so
  introspection returns `nil` for it — that is how you tell "finished" from
  "never started".

Persistence is skipped entirely when there is no `jid` (`persistable?`), which
is what makes `MyJob.new.perform` in a unit test a plain in-memory run with no
Redis writes.

---

## 4. Interruption and resumption

| Event | What the run loop sees | Result |
|---|---|---|
| `TERM` / `INT`, in-flight finishes before `shutdown_timeout` | nothing — the loop runs to completion | job completes normally |
| `TERM` / `INT`, still running at the deadline | `Wurk::Shutdown` (a subclass of `Interrupt`) raised into the thread | the unit of work is bulk-requeued; the job re-runs later and resumes from the **last periodic checkpoint** |
| `TSTP` (quiet) | nothing | in-flight iteration continues to completion; no new jobs are fetched |
| `USR1` (rolling restart) | same as `TERM` on the old slot | same as `TERM` |
| `SIGKILL` | nothing | the payload is still in the process's private list and is reclaimed on next boot; resumes from the last checkpoint |
| `Wurk::Job::Interrupted` raised | `rescue Interrupted` in `perform` | **final** flush, `on_stop`, re-raise → `InterruptHandler` re-pushes at the head of the queue |

Only the last row gets a final flush and an immediate head-of-queue re-push.
The `Wurk::Shutdown` path is a hard kill: the last periodic checkpoint is what
survives, and redelivery comes from reliable fetch reclaiming the private list.

### Interrupting cooperatively

The run loop raises `Interrupted` on its own **only for cancellation** (§5). It
does not poll the processor's shutdown flag. If you want a long single iteration
to bail out early on shutdown, check it yourself — `interrupted?` comes from
`Wurk::Worker` and is true once the processor is stopping:

```ruby
def each_iteration(batch)
  raise Wurk::Job::Interrupted if interrupted?

  batch.each { |row| process(row) }
end
```

That raise is caught by `Wurk::Middleware::InterruptHandler`, which is
**prepended to the top of the server chain automatically** when Wurk loads. It
re-pushes the unchanged job JSON with `LPUSH queue:<queue>` — head of queue, so
it is the next thing fetched — and then raises `Wurk::JobRetry::Skip` so the
retry layer books it as a clean exit rather than a failure. The payload is not
modified; the cursor rides in Redis, not in the job args.

> Never `rescue Wurk::Job::Interrupted` in your own code. Swallowing it turns a
> resumable interruption into silent data loss.

---

## 5. Cancellation

Cancellation is cooperative and cross-process. From inside the job:

```ruby
def each_iteration(item)
  cancel! if budget_exhausted?
  # ...
end
```

From outside, given a jid:

```ruby
Wurk::Client.new.cancel!(jid)   # => epoch-seconds timestamp
```

Both write `cancelled` into `it-<jid>` and drop the TTL to `CANCELLATION_PERIOD`
(3 days). `cancel!` from inside the job also sets an in-process flag so the
**next** iteration trips immediately; other processes observe the flag on their
next poll, which is rate-limited to once per `STATE_FLUSH_INTERVAL` to keep the
hot loop cheap. So worst-case latency for an external cancel is ~5 seconds plus
the duration of the current iteration.

`cancelled?` returns the combined answer (local flag, or a remote poll).

When the flag trips, the loop raises `Interrupted` **before** running the next
iteration — the item at the current cursor is not processed.

---

## 6. Lifecycle callbacks

All five are no-op instance methods you override. Exact names and firing order:

| Callback | Fires |
|---|---|
| `on_start` | once per jid, before the first iteration, when `ex == 0` |
| `on_resume` | instead of `on_start`, when loaded state has `ex > 0` |
| `around_iteration` | wraps every `each_iteration` call; must `yield` |
| `on_cancel` | on interruption, only when the job was cancelled |
| `on_stop` | on **every** interruption, after `on_cancel` |
| `on_complete` | after the final flush, before the state HASH is deleted |

Ordering on the two terminal paths:

```
completion:    … → flush(final) → on_complete → DEL it-<jid>
interruption:  … → flush(final) → on_cancel (if cancelled) → on_stop → re-raise
```

`on_stop` fires for a cancellation too — it is "the loop stopped early", not
"the loop stopped without being cancelled". `on_complete` and `on_stop` are
mutually exclusive.

`around_iteration` is the hook for per-item instrumentation, timeouts, or
transactions:

```ruby
def around_iteration
  ActiveRecord::Base.transaction { yield }
end
```

Inside any callback or iteration you can read:

| Reader | Value |
|---|---|
| `current_object` | the item currently being processed |
| `cursor` | the cursor of the last **completed** iteration (`nil` before the first) |
| `arguments` | the job's `perform_async` args, as an Array |
| `iteration_key` | `"it-#{jid}"` |

---

## 7. Retries

An exception other than `Interrupted` propagates out of `perform` untouched and
lands in the normal retry machinery — same `sidekiq_options retry:` semantics as
any other job.

The cursor is **not** finalized on that path: there is no final flush, so the
retry resumes from whatever the last five-second checkpoint held. Because a
retry keeps the same `jid`, the retried run reads the same `it-<jid>` HASH,
fires `on_resume` (since `ex > 0`), and picks up mid-way. This is the desired
behavior for a backfill — but it means **a retry does not start clean**. If your
job needs an all-or-nothing restart, delete the state key or use a fresh jid.

A job that exhausts its retries and lands in the dead set leaves its `it-<jid>`
HASH behind until the 30-day TTL expires. Retrying it from the dashboard reuses
the jid, so it resumes rather than restarts.

---

## 8. Introspection

`Wurk::IterableJobQuery` is the read side: a bulk, pipelined `HGETALL` over many
`it-<jid>` keys in one round trip.

```ruby
q = Wurk::IterableJobQuery.new([jid1, jid2, jid3])

state = q[jid1]        # => State, or nil if no it-<jid> HASH exists
state.executions       # => Integer  (ex)
state.runtime          # => Float    (rt, seconds)
state.cursor           # => the JSON-decoded cursor (c)
state.cancelled        # => Integer epoch seconds, or nil

q.each { |s| … }       # Enumerable; skips jids with no state, keeps input order
```

`nil` from `[]` means one of three things: the jid is not an iterable job, it
completed (state deleted), or its state expired. There is no "finished"
sentinel.

For a single job you already hold a `JobRecord` for:

```ruby
Wurk::Queue.new("default").each do |job|
  state = job.iterable_state   # => IterableJobQuery::State | nil
  next unless state

  puts "#{job.jid}: cursor=#{state.cursor} runs=#{state.executions}"
end
```

**There is no dashboard UI for iterable progress.** Nothing under `app/` or the
SolidJS frontend reads iteration state, and the JSON API does not expose it —
`IterableJobQuery` and `JobRecord#iterable_state` are Ruby-only surfaces today.
Build your own admin view on top of them if you need one.

---

## 9. Sidekiq compatibility

| Upstream constant | Resolves to |
|---|---|
| `Sidekiq::IterableJob` | `Wurk::IterableJob` |
| `Sidekiq::IterableJobQuery` | `Wurk::IterableJobQuery` |
| `Sidekiq::Job::Iterable` | `Wurk::IterableJob` (upstream homes the module here) |
| `Sidekiq::Job::Iterable::CsvEnumerator` | `Wurk::IterableJob::CsvEnumerator` |
| `Sidekiq::Job::Iterable::ActiveRecordEnumerator` | `Wurk::IterableJob::ActiveRecordEnumerator` |
| `Sidekiq::Job::Interrupted` | `Wurk::Job::Interrupted` |
| `Sidekiq::Job::InterruptHandler` | `Wurk::Middleware::InterruptHandler` |

`Wurk::IterableJob::Interrupted` is the same class as `Wurk::Job::Interrupted`;
the alias exists so code that rescues or raises either name behaves identically.

Key schema, field names, cursor semantics, and the 5-second check interval all
match upstream, so a half-finished Sidekiq iterable job resumes correctly after
the gem swap and vice versa.

---

## 10. Gotchas

- **`each_iteration` must be idempotent.** The cursor stored for an item is
  that item's own index/primary key, and resumption *includes* it — resuming
  from cursor `2` re-yields the element at index `2`. At least one item is
  always replayed after an interruption, and up to five seconds' worth after a
  hard kill.
- **`build_enumerator` must be deterministic.** It is re-invoked from scratch on
  every resume. A relation ordered non-deterministically, a query whose result
  set shifts as you mutate it (`User.where(migrated: false)` while
  `each_iteration` sets `migrated = true`), or a `Dir.glob` over a changing
  directory will skip or duplicate work. Prefer a stable ordering and an
  immutable snapshot, or accept — deliberately — that the set shrinks under you.
- **Keep args small.** `*args` is the job payload, re-serialized into Redis on
  every re-push. Pass an id, not a 10 MB array — the enumerator exists precisely
  so the big collection never enters the payload.
- **The cursor must survive JSON.** Symbols, `Time`s, and AR objects do not
  round-trip. Store the primary key.
- **Checkpoint cadence is a constant, not config.** `STATE_FLUSH_INTERVAL` is
  fixed at 5 seconds for both flushing and cancellation polling. Iterations
  should be short enough that a five-second granularity is meaningful; a single
  iteration that takes ten minutes checkpoints once, at its end.
- **A cancelled job that gets re-pushed stays cancelled.** The `cancelled` field
  outlives the run, so the resumed execution trips on its very first check and
  interrupts again. That flag lives for `CANCELLATION_PERIOD` (3 days).
- **Define `include Wurk::IterableJob` before any `perform`.** The
  `method_added` guard is installed by the include and cannot see methods
  defined above it.

---

## Related

- [Starting the Wurk process](running.md) — signals, shutdown timeout, quiet.
- [Deploying Wurk](deployment.md) — rolling restarts and what interrupts jobs.
- [Migrating from Sidekiq](migrate-from-sidekiq.md) — the alias contract.
