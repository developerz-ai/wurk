# Batches

A **batch** is a group of jobs with a shared identity in Redis and callbacks
that fire when the group reaches a terminal state. You enqueue N jobs, and Wurk
tells you when all N succeeded (`:success`), when all N stopped running
(`:complete`), or when one of them died for good (`:death`) — without you
polling, chaining, or writing a counter of your own.

Use one when the *aggregate* matters: "email the report once every shard
finished", "flip the feature flag after the backfill completes", "page someone
if any row of this import dies". If you only care about individual jobs, you
don't need a batch.

This is Sidekiq Pro's Batches feature, in the same gem, free. Every class is
exposed under its Sidekiq name — `Sidekiq::Batch`, `Sidekiq::BatchSet`,
`Sidekiq::Batch::Status`, `Sidekiq::Batch::DeadSet`, `Sidekiq::Pro::BatchStatus`
— so existing Pro code and existing batch data in Redis keep working on the
one-line gem swap.

| Surface | Class | Purpose |
|---|---|---|
| `Sidekiq::Batch` | `Wurk::Batch` | Create/reopen a batch, register callbacks, enqueue jobs |
| `Sidekiq::Batch::Status` | `Wurk::Batch::Status` | Read-only snapshot of a batch by bid |
| `Sidekiq::BatchSet` | `Wurk::BatchSet` | Enumerate all batches, tag lookup |
| `Sidekiq::Batch::DeadSet` | `Wurk::Batch::DeadSet` | Enumerate batches that hit `:death` |
| `Sidekiq::Pro::BatchStatus` | `Wurk::Web::BatchStatus` | Rack middleware serving batch JSON for progress bars |

---

## Creating a batch

```ruby
batch = Sidekiq::Batch.new
batch.description = "Nightly import for account #{account.id}"
batch.on(:success, ImportCallback, "account_id" => account.id)

batch.jobs do
  rows.each { |row| ImportRowJob.perform_async(row.id) }
end

batch.bid   # => "kx3Hs9dQ0aTZbA" — hand this to your UI, store it, poll it
```

`Batch.new` allocates a fresh bid (URL-safe base64 of 10 random bytes) but
writes **nothing** to Redis. The first `#jobs` call is what flushes: it `HSET`s
the core `b-<bid>` hash, adds the bid to the global `batches` sorted set, writes
the tag indexes, and stamps the expiry.

Inside the block, every `perform_async` is stamped with the batch's bid by the
batch client middleware (the active batch lives in
`Thread.current[:wurk_current_batch]`), and each push goes through a single Lua
script that increments `total`/`pending`, registers the jid in the live set, and
`LPUSH`es the payload — atomically, so a batch's counters can never disagree
with its queue contents.

An **empty** `#jobs` block is legal: Wurk enqueues a `Wurk::Batch::Empty` no-op
marker so the callbacks still fire rather than the batch hanging at `total: 0`
forever.

`perform_in` / `perform_at` inside the block work too — a scheduled job is
registered into the batch at *creation* time (not at promotion), so `total` and
`pending` reflect it immediately.

### Instance API

| Method | Returns | Notes |
|---|---|---|
| `#bid` | String | Batch id, generated at `new` |
| `#description` / `#description=` | String | Shown in the dashboard |
| `#callback_queue` / `#callback_queue=` | String | Queue for callback jobs (default `"default"`) |
| `#callback_class` / `#callback_class=` | String or Class | The class a bare `"#method"` callback spec resolves against. A `Class` is normalized to its name; set it **before the first `#jobs` call** |
| `#tags` / `#tags=` | Array&lt;String&gt; | Coerced to strings; indexed at `tags:<tag>` |
| `#autoflush` / `#autoflush=` | `true` or positive Integer | Buffer pushes inside `#jobs` |
| `#linger` / `#linger=` | Integer seconds | Post-success retention override |
| `#parent_bid` | String / nil | Set when flushed inside another batch's `#jobs` block |
| `#parent` | `Sidekiq::Batch` / nil | Reopened parent batch |
| `#mutable?` | Boolean | True until the first `#jobs` flush; false for a reopened batch |
| `#include?(jid)` | Boolean | Is this jid still live in the batch |
| `#remove_jobs(*jids)` | Integer | Drops jids from the live set, decrements `total`/`pending` by the number actually removed |
| `#invalidate_all` | nil | Marks this batch and every descendant invalid |
| `#valid?` | Boolean | False once invalidated |
| `#status` | `Batch::Status` | Snapshot |
| `#expires_in(duration)` | self | Overrides the 30-day pending TTL; chainable |
| `#on(event, target, options = {})` | self | Register a callback |
| `#jobs { … }` | self | Enqueue block |

`Batch.new(bid)` **reopens** an existing batch: it `HGETALL`s the hash and
restores description, callback queue, tags, linger and callbacks. Reopening is
for jobs and callbacks — `mutable?` is false, because the first flush already
happened.

### autoflush

By default each `perform_async` inside `#jobs` is its own Redis round-trip.
`autoflush` buffers them instead:

```ruby
batch = Sidekiq::Batch.new
batch.autoflush = true     # buffer the whole block, flush once at exit
batch.autoflush = 500      # flush every 500 jobs
```

Anything else truthy (`0`, `-1`, `"5"`) raises `ArgumentError` rather than
silently degrading. Scheduled (`at`) jobs bypass the buffer.

---

## Callbacks

```ruby
batch.on(:success,  ImportCallback, "account_id" => 42)
batch.on(:complete, "ImportCallback#finished", "account_id" => 42)
batch.on(:death,    PagerCallback)
```

The target may be a Class, a `"Klass"` string, a `"Klass#method"` string, or a
class-less `"#method"` string that resolves against the batch's
`callback_class`. Anything else raises `ArgumentError`, as does an unknown
event or a non-Hash `options`.

| Target | Invokes |
|---|---|
| `ImportCallback` | `ImportCallback.new.on_success(status, options)` |
| `"ImportCallback"` | `ImportCallback.new.on_success(status, options)` |
| `"ImportCallback#finished"` | `ImportCallback.new.finished(status, options)` |
| `"#finished"` | `<callback_class>.new.finished(status, options)` |

Set `callback_class` **before the first `#jobs` call** if you use the
class-less form — like `description` and `tags`, it is only persisted at first
flush, and a `"#method"` target can't resolve without it.

A target that can't be resolved at run time — unknown constant, a module rather
than a class, a missing or private method, or a class-less form with no
`callback_class` — raises `Wurk::Batch::CallbackJob::UnresolvableTarget` and
goes **straight to the dead set on the first attempt** rather than retrying for
25 attempts. A `NameError` doesn't heal with time, so you see it in the Dead
tab immediately; fix the class and retry the entry from there. Errors raised by
the callback body itself keep the normal retry backoff.

The contract is a **class with a no-argument constructor**:

```ruby
# app/jobs/import_callback.rb
class ImportCallback
  def on_success(status, options)
    Account.find(options["account_id"]).touch(:imported_at)
  end

  def on_complete(status, options)
    Rails.logger.info("batch #{status.bid}: #{status.failures} still failing")
  end

  def on_death(status, options)
    Pager.alert("import #{status.bid} lost #{status.dead_jids.size} jobs")
  end

  # "ImportCallback#finished" calls this instead of on_<event>
  def finished(status, options); end
end
```

`status` is a `Sidekiq::Batch::Status` built fresh from the bid. `options` is
the hash you passed to `#on`, round-tripped through **JSON** — so keys come back
as strings and only JSON types survive. Never pass an ActiveRecord object; pass
its id.

Multiple callbacks per event are fine; they run as independent jobs.

### When each fires

| Event | Fires when | Semantics |
|---|---|---|
| `:complete` | The live-jid set drains — every job either succeeded or died — and every child batch has finished | At most once per batch |
| `:success` | `:complete`'s condition, plus `pending == 0` and no death anywhere in the subtree | At most once per batch |
| `:death` | A job exhausts its retries (or carries `dead: false` and is discarded) and the batch's died set goes from empty to non-empty | At most once per batch, ever |

- `:success` and `:death` are not mutually exclusive over time. A death
  suppresses `:success` while it stands; if you retry the dead job from the
  morgue and it succeeds, the batch's death mark clears and `:success` can fire
  later. `:death` itself never fires twice — its dedup key survives the
  recovery.
- Child batches fire before their parent: a parent's `:complete`/`:success` are
  gated on `b-<bid>-pkids` (pending children) being empty.
- A death cascades **up** the parent chain: every ancestor gets `:death` and
  loses its chance at `:success` until the subtree recovers.
- At-most-once is enforced with `SET NX` marker keys (`b-<bid>-success`,
  `-complete`, `-death`), so racing workers acking the last job can't
  double-fire.

### How callbacks run

Callbacks are **ordinary jobs**, not in-process hooks. Wurk enqueues a
`Wurk::Batch::CallbackJob` onto the batch's `callback_queue` with
`retry: true`, and that job instantiates your class and calls the method.

Consequences, all of them load-bearing:

- **Your callback runs in a worker process**, minutes later, possibly on another
  host. It has no access to whatever was in scope when you built the batch.
- **It retries like any job**, so it must be idempotent.
- **A worker must be listening on `callback_queue`.** Set it to a queue your
  fleet actually consumes — the default is `"default"`.
- One callback raising during *enqueue* is logged and skipped; the other
  callbacks for that event still fire.

### Registering callbacks late

`#on` before the first `#jobs` buffers in memory and is written with the first
flush. `#on` **after** the first flush — or on a batch reopened by bid —
appends to Redis immediately via an atomic server-side Lua append, so
concurrent registrations from different processes can't clobber each other.

Two things to know about the late path:

- Registering on a batch whose Redis hash is gone (expired, deleted) raises
  `ArgumentError`.
- Registering for an event that **already fired** logs a warning and the
  callback never runs.

---

## `Batch::Status`

```ruby
status = Sidekiq::Batch::Status.new(bid)
return render_404 unless status.exists?
```

Construction `HGETALL`s `b-<bid>` once; the readers below are served from that
snapshot unless noted. A blank bid raises `ArgumentError`.

| Method | Returns | Source |
|---|---|---|
| `#bid` | String | — |
| `#exists?` | Boolean | False when `b-<bid>` is gone (never created, or expired) |
| `#total` | Integer | Distinct jobs added |
| `#pending` | Integer | Not yet succeeded (a death does **not** decrement it) |
| `#failures` | Integer | Jobs *currently* in a failing/retrying state |
| `#created_at` / `#complete_at` / `#success_at` / `#death_at` | Float epoch / nil | Event timestamps |
| `#complete?` | Boolean | Hash flag, falling back to a live recount |
| `#invalidated?` | Boolean | Set by `invalidate_all` |
| `#description` / `#parent_bid` / `#callback_queue` | String / nil | — |
| `#tags` | Array&lt;String&gt; | Parsed from the hash; `[]` on malformed JSON |
| `#failed_jids` | Array&lt;String&gt; | Live `SMEMBERS b-<bid>-failed` |
| `#dead_jids` | Array&lt;String&gt; | Live `SMEMBERS b-<bid>-died` |
| `#child_count` | Integer | Live `SCARD b-<bid>-kids` |
| `#failure_info` | `[]` | Deprecated pre-Pro-8 surface; always empty (see [Divergences](#divergences-from-sidekiq-pro)) |
| `#data` | Hash | JSON-serializable summary — what the dashboard and polling endpoint serve |
| `#reload!` | self | Re-reads the hash |
| `#join` | nil | Blocks the calling thread, polling every 0.5s until `complete?` |
| `#delete` | nil | `UNLINK`s every batch key and drops the bid from `batches`/`dead-batches` |

`#join` is for tests and scripts. Calling it from a worker thread burns a thread
waiting on Redis and defeats the point of asynchronous batches.

`#delete` while jobs are in flight leaves those jobs acking against a batch that
no longer exists: callbacks won't fire and counts stay inconsistent. It also
leaves the `SET NX` callback dedup keys behind (they carry their own 30-day
TTL), so a recreated batch under the same bid would not re-fire.

`failures` is a gauge, not a counter: it goes up when a job raises and down when
that job's retry finally succeeds or when it dies. A batch where every failure
eventually passed reports `failures: 0`.

### Progress polling without the dashboard

```ruby
# config.ru
use Sidekiq::Pro::BatchStatus
run Rails.application
```

`GET /batch_status/<bid>.json` returns `Status#data` as JSON; an unknown or
expired bid returns 404, and every other request passes straight through. That
is the whole middleware — drive your progress bar off `total`, `pending`,
`failures`, `complete`.

---

## Reading the batch from inside a job

Every job class gets three helpers, whether or not it was enqueued in a batch:

```ruby
# app/jobs/import_row_job.rb
class ImportRowJob
  include Sidekiq::Job

  def perform(row_id)
    return unless valid_within_batch?   # batch was invalidate_all'd — skip

    bid     # => "kx3Hs9dQ0aTZbA", or nil outside a batch
    batch   # => Sidekiq::Batch (reopened by bid), or nil

    batch&.jobs do                      # add siblings to my OWN batch
      FollowUpJob.perform_async(row_id)
    end
  end
end
```

There is no `Batch.current` — `bid` and `batch` on the job instance are the
access path, populated from `job_hash['bid']` before `perform` runs.

Adding jobs to your own batch from inside a job is legal and grows `total`,
which is how you fan out work whose shape isn't known up front. The batch is
only "done" once these later jobs finish too.

---

## Nesting

Open a batch inside another batch's `#jobs` block and it links automatically:
`parent_bid` is recorded, and the child bid joins the parent's `b-<bid>-kids`
(all children) and `b-<bid>-pkids` (children not yet finished) sets. The parent
can't fire `:complete` or `:success` until every child's subtree has drained.

The two legal moves:

- A **job** opens its own batch (`batch.jobs { … }`) to add siblings.
- A **callback** opens its **parent** batch (`Sidekiq::Batch.new(status.parent_bid)`)
  to start the next stage of a workflow.

```ruby
# app/jobs/fulfillment_callbacks.rb
class FulfillmentCallbacks
  def step1_done(status, options)
    parent = Sidekiq::Batch.new(status.parent_bid)
    parent.jobs do
      step2 = Sidekiq::Batch.new
      step2.on(:success, "FulfillmentCallbacks#step2_done", "oid" => options["oid"])
      step2.jobs do
        PackJob.perform_async(options["oid"])
        LabelJob.perform_async(options["oid"])
      end
    end
  end
end
```

A callback cannot mutate the batch it belongs to — that batch is already
terminal, and `#on` against it would only log the "already fired" warning.

---

## Failure handling

| What happens | Effect on the batch |
|---|---|
| Job raises, will retry | jid joins `b-<bid>-failed`, `failures` +1 (idempotent per jid) |
| Retry finally succeeds | jid leaves `failed`, `failures` -1, `pending` -1 |
| Job exhausts retries (or `dead: false` discard) | jid moves `failed` → `b-<bid>-died`, leaves the live set, `:death` fires, batch joins `dead-batches`. **`pending` is not decremented** |
| Dead job retried from the morgue and succeeds | jid rejoins the live set with no recount; when the died set drains, the death mark clears and `:success` becomes reachable again |
| Batch invalidated | Jobs stay queued but the server middleware short-circuits them; they ack as successes without running |

Because a death leaves `pending` untouched, a batch with a dead job reaches
`:complete` (live set empty) but never `:success` — exactly the signal you want.

`Sidekiq::Batch::DeadSet.new.each { |status| … }` enumerates every batch that
hit `:death`, newest first.

Clean, handled exits are neither a success nor a failure and ack nothing: a
shutdown interrupt, a rate-limiter reschedule, and cooperative `IterableJob`
interruption all leave the jid live so the retry counts once.

---

## Discovery

```ruby
Sidekiq::BatchSet.new.size                      # ZCARD batches

Sidekiq::BatchSet.new.each do |status|          # newest first, 100 bids per page
  puts "#{status.bid} #{status.pending}/#{status.total}"
end

Sidekiq::BatchSet.new.scan_tags("customer:1234") do |bid|
  Sidekiq::Batch::Status.new(bid)
end
```

`BatchSet` is `Enumerable`, so `first`, `take`, `select`, `lazy` all work — but
`#each` builds a `Status` per bid, and each `Status` is a Redis round-trip.
Iterating a set with hundreds of thousands of batches costs accordingly; prefer
`scan_tags` (bids only, no parsing) when you know the tag.

The dashboard's **Batches** page paginates `BatchSet` and shows bid,
description, total, pending, failures, a progress bar and creation time. The
detail page adds tags, parent bid, child count, completion time, the invalidated
badge, and the failed/dead jid lists — all straight from `Status#data`, served
by `GET /api/batches` and `GET /api/batches/:bid`.

---

## Expiry and Redis footprint

| Phase | TTL | Constant |
|---|---|---|
| Pending (from first flush) | 30 days | `Batch::DEFAULT_EXPIRY_SECONDS`, override per batch with `expires_in` |
| After `:success` fires | 24 hours | `Batch::POST_SUCCESS_EXPIRY_SECONDS`, override per batch with `linger=` |
| Callback dedup markers | 30 days | `Batch::CALLBACK_NOTIFY_TTL` |

A batch costs one hash (`b-<bid>`) plus the sub-keys it actually needs —
`-jids`, `-failed`, `-died`, `-kids`, `-pkids`, plus the three callback dedup
markers (`-complete`, `-success`, `-death`) — each holding at most one entry
per job, child, or fired event. **Every sub-key is TTL'd at the site that
creates it**, not swept later:

- `BATCH_PUSH`, `BATCH_SCHEDULE`, `BATCH_ACK_FAILED` and `BATCH_ACK_COMPLETE`
  (the Lua scripts in `lib/wurk/lua.rb`) each `EXPIRE … NX` the sub-key(s) they
  create, using `Batch::DEFAULT_EXPIRY_SECONDS`.
- `link_to_parent` stamps `-kids`/`-pkids` the same way when a child batch first
  links to its parent.
- `Callbacks#record_event` stamps `b-<bid>` itself `NX` when a callback fires,
  since a child batch outliving its parent's window can resurrect that hash
  with an `HSET`.
- `Callbacks#dedup_set` writes the dedup markers with `SET … EX` directly
  (`CALLBACK_NOTIFY_TTL`), so they never need a separate stamp.

`NX` everywhere means only a key with *no* TTL gets one — a live batch's clock,
and the shorter post-success `linger` window, are never overwritten. The
footprint is bounded entirely by TTL: Wurk never sweeps a whole batch, Redis
expires the pieces individually as they age out.

The two index ZSETs — `batches` (all batches, scored by creation time) and
`dead-batches` (batches that fired `:death`, scored by death time) — are
bounded on a second axis: member count, not just TTL. `Batch.trim_index`
(`lib/wurk/batch.rb`) runs in the same pipeline as the `ZADD` that grows each
set:

- `ZREMRANGEBYSCORE key -inf (cutoff` evicts entries older than the trim
  window (`DEFAULT_EXPIRY_SECONDS` by default — the same window as the batch
  hash TTL, so an index entry retires in step with the data it points at).
- `ZREMRANGEBYRANK key 0 -max` caps the member count at `Batch::INDEX_MAX`
  (1,000,000) as a backstop, same shape as `DeadSet#trim`'s rank-based cap.

Without this, nothing ever shrinks either set — `Status#delete` and the
death-recovery `ZREM` are the only other removals, both manual — so `batches`
and `dead-batches` grew for the life of the Redis instance regardless of TTL
on the underlying hashes. A batch that overrides `expires_in` beyond the trim
window outlives its index entry: still reachable by bid, just no longer
enumerated by `BatchSet` or `DeadSet`.

Two behaviours worth knowing:

- A job that dies **after** its batch keys expired would recreate them with no
  TTL. The death handler (`DeathHandler.restamp_ttls`) re-stamps every sub-key
  with `EXPIRE … NX` on death — the one moment the batch is known to be
  winding down — so resurrected keys get a clock and live batches keep theirs.
- `linger=` on an already-flushed batch writes straight to Redis, so it works on
  a batch reopened by bid. `description=`, `callback_queue=`, `callback_class=`,
  `tags=` and `expires_in` do **not** — they are only persisted by the first
  flush. Set them before the first `#jobs` call.

---

## Testing

`Sidekiq::Testing.fake!` and `inline!` short-circuit `Client#raw_push` before
the Redis write, and the inline server-middleware chain is empty by default.
What that means for batches:

- `Batch#jobs` still talks to Redis — the `b-<bid>` hash and the `batches` entry
  are created for real.
- The jobs themselves are **not** registered into the batch: no `BATCH_PUSH`, so
  `total` and `pending` stay `0`, and the empty-marker job is enqueued as if the
  block had been empty.
- No acks and therefore **no callbacks**, in either mode.
- `bid` and `batch` inside a job still work — `process_job` sets the bid from
  the payload.

So `fake!`/`inline!` are right for asserting that your code *enqueued* what you
expected (`ImportRowJob.jobs.size`, and each payload carries a `bid`), and wrong
for asserting callback behaviour.

Two ways to test the rest:

```ruby
# Call the callback object directly — it's a plain class, not a job.
ImportCallback.new.on_success(Sidekiq::Batch::Status.new(bid), { "account_id" => 42 })
```

```ruby
# Or opt the batch middleware into the inline chain so acks and callbacks run.
Sidekiq::Testing.server_middleware { |c| c.add(Wurk::Batch::ServerMiddleware) }
```

Wurk's own batch suites take neither: real Redis, real forks, and assertions
against the callback queue's contents. Never mock Redis for batch tests — the
whole feature is Lua-script atomicity.

---

## Divergences from Sidekiq Pro

Wurk implements the batch surface in `docs/target/sidekiq-pro.md` §2. Two
deliberate differences:

- **`Status#failure_info` always returns `[]`.** The Pro 8 data model drops the
  `b-<bid>-failinfo` hash in favour of the `failed_jids` set, which Wurk tracks;
  per-jid error payloads are intentionally not persisted. The method exists so
  drop-in callers don't `NameError`.
- **`#autoflush` accepts `true` as well as a positive Integer.** `true` buffers
  the whole `#jobs` block and flushes once at exit; an Integer flushes every N.
  Values Pro would silently accept (`0`, `"5"`) raise `ArgumentError`.

---

## Related

- [Migrating from Sidekiq](migrate-from-sidekiq.md) — what a one-line gem swap
  does and doesn't change.
- [Dashboard](dashboard.md) — the Batches pages, and gating them.
- [Running Wurk](running.md) — making sure a worker actually consumes your
  `callback_queue`.
