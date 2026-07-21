# Middleware

Wurk runs every enqueue and every job execution through an ordered chain of
middleware. There are two chains, and they are completely separate:

| Chain | Runs in | Wraps | Registered on |
|---|---|---|---|
| **Client** | whatever process calls `perform_async` (web, console, another worker) | the Redis write in `Wurk::Client#push` | `config.client_middleware` |
| **Server** | the worker process | `instance.perform(*args)` in `Wurk::Processor` | `config.server_middleware` |

Both chains are `Wurk::Middleware::Chain` instances with an identical
manipulation API. The middleware contract is Sidekiq's, unchanged: an existing
`Sidekiq.configure_server { |c| c.server_middleware.add … }` initializer keeps
working on the one-line gem swap, because `Sidekiq::Middleware`,
`Sidekiq::ServerMiddleware`, and `Sidekiq::ClientMiddleware` are aliases of the
`Wurk::*` constants.

---

## The two `call` signatures

**They differ by one argument.** Client middleware takes four; server
middleware takes three. Getting this wrong is the most common authoring bug.

### Client middleware

```ruby
# config/initializers/wurk.rb
class MyClientMiddleware
  include Wurk::Middleware::ClientMiddleware

  def call(job_class, job, queue, redis_pool)
    yield
  end
end
```

- `job_class` — the job class **name as a String**. `Wurk::JobUtil` stringifies
  it (`normalized['class'] = job_class.to_s`) before the chain runs, so don't
  expect a Class object.
- `job` — the normalized job hash, string keys, mutable. Anything you write
  here is what lands in Redis.
- `queue` — the queue name String (already stringified and validated
  non-empty).
- `redis_pool` — the pool the push will use.

**The return value decides whether the push happens.** `Wurk::Client#push`
does:

```ruby
payload = invoke_chain(normed)
return nil unless payload
```

So `yield`'s value must be returned for the push to proceed. Returning `nil` or
`false` **halts the push** — the job is silently dropped and `perform_async`
returns `nil` instead of a jid. In `push_bulk`, a halted job contributes a `nil`
entry to the returned jid array. `Wurk::Unique::ClientMiddleware` uses exactly
this to drop duplicates.

### Server middleware

```ruby
# config/initializers/wurk.rb
class MyServerMiddleware
  include Wurk::Middleware::ServerMiddleware

  def call(job_instance, job, queue)
    yield
  end
end
```

- `job_instance` — the **instantiated** worker, with `jid` (and `bid` when
  batched) already assigned. Not the class.
- `job` — the parsed job hash.
- `queue` — the queue name String.

There is no fourth argument and no `redis_pool` parameter — reach for the pool
through the `redis_pool` / `redis` helpers the mixin gives you (below).

A server middleware that returns without yielding **skips `perform`** without
raising. The processor sees a clean exit and acks the unit of work.
`Wurk::Middleware::Expiry` does this.

### The mixin

`include Wurk::Middleware::ServerMiddleware` (or `ClientMiddleware` — they are
the same module; `ClientMiddleware = ServerMiddleware`) gives you:

| Method | Returns |
|---|---|
| `config` / `config=` | the bound `Wurk::Configuration` or `Wurk::Capsule` |
| `redis_pool` | `config.redis_pool` |
| `redis(&)` | `config.redis(&)` — checkout + yield a connection |
| `logger` | `config.logger` |

`config=` is assigned by the chain at instantiation time
(`Entry#make_new(config)`), only if the instance responds to it. Including the
mixin is the supported way to get it.

---

## Registering middleware

### Where to register

Register at **boot**, from an initializer, before the swarm forks. The boot
order is:

1. Host app boots; `config/initializers/*` run — this is where you register.
2. The railtie's `after_initialize` fires.
3. The swarm closes parent-side Redis/DB sockets.
4. The swarm forks N children.
5. Each child reconnects and starts fetching.

Chains registered in step 1 are inherited by every fork, because the entries
are plain Ruby objects copied by `fork`. **Registering after the fork only
affects the process that did it** — a call from inside a job body mutates that
one child's chain and nothing else.

The fork-safety rule follows from the same place: the chain stores a **klass
plus constructor args**, not a live instance, and `Chain#retrieve` builds a
fresh instance per job. So middleware never carries a Redis connection, a file
handle, or any other fork-hostile state across the fork boundary — provided you
don't open one in `initialize`. Open connections lazily inside `call`, or use
`redis_pool`, which resolves through the per-fork pool.

### `configure_server` vs `configure_client`

Both blocks yield the same global `Wurk::Configuration`; the difference is a
gate on `config.server?`:

```ruby
def configure_server(&block) = yield self if block && server?
def configure_client(&block) = yield self if block && !server?
```

So:

```ruby
# config/initializers/wurk.rb
Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add MyServerMiddleware
  end
  config.client_middleware do |chain|
    chain.add MyClientMiddleware   # jobs enqueued *from* jobs
  end
end

Sidekiq.configure_client do |config|
  config.client_middleware do |chain|
    chain.add MyClientMiddleware   # web/console enqueues
  end
end
```

Client middleware you want on **both** sides must be registered in both blocks,
or outside either block entirely (a bare
`Wurk.configuration.client_middleware.add …` always runs).

Server mode is entered *before* `config/initializers` load — the railtie's
`wurk.server_mode` initializer calls `Wurk.enter_server_mode`, and the
standalone CLI does the same before booting the app. That ordering is
load-bearing: if it were reversed, every `configure_server` block would be
silently skipped and your server middleware would never register.

Both chain readers accept a block *or* return the chain, so
`config.server_middleware.add(X)` and `config.server_middleware { |c| c.add X }`
are equivalent.

### The chain API

Every method is available on both chains:

| Method | Effect |
|---|---|
| `add(klass, *args)` | Remove any existing entry for `klass`, then **append**. Appended = innermost. |
| `prepend(klass, *args)` | Remove any existing entry, then insert at index 0 = **outermost**. |
| `insert_before(oldklass, newklass, *args)` | Move/insert `newklass` immediately before `oldklass`. If `oldklass` isn't registered, falls back to index 0. |
| `insert_after(oldklass, newklass, *args)` | Move/insert `newklass` immediately after `oldklass`. If `oldklass` isn't registered, falls back to the end. |
| `remove(klass)` | Delete every entry for `klass`. |
| `exists?(klass)` / `include?(klass)` | Membership test. |
| `empty?` | No entries. |
| `clear` | Drop everything, including the built-ins. |
| `entries` | The raw `Entry` array (`entry.klass` is the registered class). |
| `each` / any `Enumerable` method | Iterate entries. |
| `retrieve` | Build a fresh instance per entry. Called once per job. |
| `invoke(*args, &block)` | Walk the chain around `block`. |
| `copy_for(capsule)` | Duplicate the chain bound to a capsule. |

`*args` are passed straight to `klass.new`, which is how parameterized
middleware works:

```ruby
chain.add MyMiddleware, threshold: 500
# → MyMiddleware.new(threshold: 500) per job
```

**Ordering:** entry 0 is outermost. `add` appends, so a later `add` sits
*inside* an earlier one and runs closer to `perform`. `prepend` puts you
outermost — use it when you must see exceptions that inner middleware would
otherwise swallow (that's why `InterruptHandler` prepends).

`invoke` raises `ArgumentError` without a block, and short-circuits to a plain
`yield` when the chain is empty.

### Capsules

Capsules get their own chain via `copy_for`, which duplicates the entries array
and rebinds `@config` to the capsule — so `redis_pool` / `logger` inside
middleware resolve against that capsule, not the global config. Mutating a
capsule's chain does not affect the global one, and vice versa, **after** the
copy is taken. The copy is taken lazily on first access (and forced by
`Capsule#prepare!` at launcher boot), so global registrations made in an
initializer are picked up.

```ruby
# config/initializers/wurk.rb
Sidekiq.configure_server do |config|
  config.capsule("critical") do |cap|
    cap.server_middleware { |chain| chain.add CriticalOnlyMiddleware }
  end
end
```

---

## A worked example

Fail a job fast when it has been sitting in the queue too long, and log the
latency — a server middleware that needs the job hash, the config, and clean
composition with retries:

```ruby
# config/initializers/wurk.rb
class QueueLatencyGuard
  include Wurk::Middleware::ServerMiddleware

  def initialize(max_seconds: 300)
    @max_seconds = max_seconds
  end

  def call(_job_instance, job, queue)
    enqueued_at = job["enqueued_at"]
    latency = enqueued_at ? Time.now.to_f - (enqueued_at.to_f / 1000.0) : 0.0

    if latency > @max_seconds
      logger.warn { "dropping stale #{job['class']} on #{queue} (#{latency.round}s old)" }
      return   # no yield → perform never runs, processor acks cleanly
    end

    yield
  end
end

Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add QueueLatencyGuard, max_seconds: 600
  end
end
```

Two things to notice. `enqueued_at` is epoch **milliseconds** — the client
stamps it with `Process.clock_gettime(CLOCK_REALTIME, :millisecond)`. And
returning instead of raising means no retry is booked; raise instead if you want
the job to go through the normal retry pipeline.

A client-side counterpart, tagging every job with the request id:

```ruby
# config/initializers/wurk.rb
class RequestIdTagger
  include Wurk::Middleware::ClientMiddleware

  def call(_job_class, job, _queue, _redis_pool)
    job["request_id"] ||= Current.request_id
    yield
  end
end

Sidekiq.configure_client { |c| c.client_middleware { |chain| chain.add RequestIdTagger } }
Sidekiq.configure_server { |c| c.client_middleware { |chain| chain.add RequestIdTagger } }
```

Note the `||=`. Client middleware runs again when a scheduled or retried job is
promoted, so an unconditional write would clobber the original value.

---

## Built-in middleware

On a default boot the chains look like this (outermost first):

**Client:** `Wurk::Batch::ClientMiddleware`

**Server:** `Wurk::Middleware::InterruptHandler` → `Wurk::Batch::ServerMiddleware`
→ `Wurk::Middleware::Expiry` → `Wurk::Limiter::ServerMiddleware`
→ `Wurk::Metrics::Statsd` → `Wurk::Metrics::History`

| Middleware | Chain | Default | Enable / disable |
|---|---|---|---|
| `Wurk::Middleware::InterruptHandler` | server | **on** (prepended at load) | `chain.remove Wurk::Middleware::InterruptHandler` |
| `Wurk::Batch::ClientMiddleware` | client | **on** (prepended at load) | no-op without a `bid`; `chain.remove` to strip |
| `Wurk::Batch::ServerMiddleware` | server | **on** | no-op without a `bid` |
| `Wurk::Middleware::Expiry` | server | **on** | no-op unless the job carries `expiry` |
| `Wurk::Limiter::ServerMiddleware` | server | **on** | only acts on `Wurk::Limiter` errors |
| `Wurk::Metrics::Statsd` | server | **on** | no-op unless `config.dogstatsd` is set |
| `Wurk::Metrics::History` | server | **on** | `chain.remove Wurk::Metrics::History` |
| `Wurk::Encryption::Client/ServerMiddleware` | both | off | registered by `Wurk::Encryption.enable(active_version:) { … }`; acts only on `encrypt: true` jobs |
| `Wurk::Unique::Client/ServerMiddleware` | both | off | registered by `Wurk::Unique.enable!` (`Sidekiq::Enterprise.unique!`); acts only on `unique_for:` jobs |
| `Wurk::Middleware::I18n::Client/Server` | both | off | `require "wurk/middleware/i18n"` |
| `Wurk::Middleware::CurrentAttributes::Save/Load` | both | off | `require` + `CurrentAttributes.persist(…)` |
| `Wurk::Middleware::PoisonPill` | *neither* | n/a | not a chain middleware — see below |

The auto-registered set is deliberately wider than stock Sidekiq's: Batch,
Expiry, Limiter, and Statsd are Pro/Ent features, and Wurk ships them enabled in
the free gem rather than behind a flag. All of them short-circuit on jobs that
don't opt in, so the cost on an unrelated job is one hash lookup.

### `InterruptHandler`

Catches `Wurk::Job::Interrupted` (raised by an `IterableJob` that hit its
interruption checkpoint, or any cooperatively cancelled job), `LPUSH`es the
unchanged job JSON back to the **head** of its queue so it's fetched next, and
raises `Wurk::JobRetry::Skip` so the retry layer books no retry and the
processor acks. Cursor state lives in the `it-<jid>` hash, not the payload —
which is why re-pushing the original JSON resumes rather than restarts.

It **prepends**, deliberately: a middleware registered inside it must not
swallow `Interrupted` before it's seen. If you add your own outermost
middleware with a broad `rescue`, you will break iterable-job resumption.

Aliased as `Wurk::Job::InterruptHandler` (hence `Sidekiq::Job::InterruptHandler`).

### `Expiry` — `expires_in`

```ruby
class ReportJob
  include Sidekiq::Job
  sidekiq_options expires_in: 1.hour
end
```

At push time `Wurk::JobUtil#stamp_expiry` converts `expires_in` into an
absolute `expiry` (epoch float) on the job hash, so the server does no date
math. Clock origin is `at` for scheduled jobs and `created_at` otherwise —
`perform_in(2.hours)` with `expires_in: 1.hour` expires at 3h, not immediately.

At execution time, if `Time.now.to_f > expiry`, the middleware:

- increments `Wurk::Processor::EXPIRED`, which the heartbeat flushes to
  `stat:expired` and `stat:expired:YYYY-MM-DD` (visible in `Wurk::Stats` and the
  dashboard),
- emits `jobs.expired` to statsd,
- returns **without yielding** — no exception, so the job is acked and no retry
  is booked.

Expiry only preempts *before* `perform` starts. A long job that started in time
runs to completion. Expired jobs still count toward `PROCESSED`
(`executed = processed - failed - expired`).

### `Limiter::ServerMiddleware`

Catches `Wurk::Limiter::OverLimit` (and anything in
`Wurk::Limiter.config.errors`), bumps `job['overrated']`, then either re-raises
(when `reschedule: 0`), re-enqueues at `Time.now + backoff` and raises
`Limiter::Rescheduled`, or — once `overrated` reaches the cap (default 20) —
routes the job to the dead set tagged `rate_limited`. Termination is bounded:
exactly `reschedule` attempts, then dead.

### `Metrics::Statsd` and `Metrics::History`

`Statsd` emits `jobs.count`, success/failure, and a perform duration
distribution. It calls `safe_client` first and yields straight through when
`config.dogstatsd` is unset, so leaving it registered costs nothing.

`History` records per-class processed / failed / total-ms into Redis time
buckets (`j|YYYYMMDD|…`) so the dashboard history pane has data on a default
boot. Both wrap their bookkeeping in a rescue — a metrics write failure never
propagates into the job result. `Wurk::Metrics::Middleware` is an alias of
`History`, matching `Sidekiq::Metrics::Middleware`.

### `I18n` — locale propagation

Opt in with a `require`. The file registers itself on load:

```ruby
# config/initializers/wurk.rb
require "wurk/middleware/i18n"
```

`I18n::Client` writes `job['locale'] ||= I18n.locale.to_s`; `I18n::Server` runs
`perform` inside `I18n.with_locale`, restoring the previous locale in an
`ensure` so nothing leaks between jobs on the same thread. Both are no-ops when
the `I18n` constant is undefined — and the client deliberately does **not**
introduce a `nil` `"locale"` key in that case, because that would change the
wire shape.

`Sidekiq::Middleware::I18n` resolves via the `Sidekiq::Middleware` alias.

### `CurrentAttributes` — request state propagation

Off by default and needs two steps — a `require` plus an explicit `persist`:

```ruby
# config/initializers/wurk.rb
require "wurk/middleware/current_attributes"

Sidekiq::CurrentAttributes.persist(Current)
# or several:
Sidekiq::CurrentAttributes.persist([Current, AuditContext])
```

`persist(klass_or_array, config = Wurk.configuration)` adds `Save` to the
client chain and `Load` to **both** the client and server chains. It raises
`ArgumentError` on an empty list. Calling it twice with the same classes is
safe — `add` dedupes by class.

Wire keys are Sidekiq's exactly: the first registered class uses `"cattr"`, the
rest `"cattr_1"`, `"cattr_2"`, … `Save` uses `job[key] ||= …`, so a
caller-supplied value wins.

`Load` **saves and restores** the surrounding attribute state rather than
resetting it. That matters because `Load` also runs on the client chain, where
an enqueue happens mid-request with request-scoped attributes already set —
blanket-resetting there would wipe the caller's state right after
`perform_async`. The restore runs in an `ensure`, so it survives both raises and
`JobRetry::Skip`.

`Load#call` takes an **optional fourth argument** (`def call(_job_or_class,
job, _queue, _redis_pool = nil)`) precisely because it is registered on both
chains, which pass different arities. If you write your own dual-chain
middleware, do the same.

The alias is the top-level `Sidekiq::CurrentAttributes`, set when the file is
required — not `Sidekiq::Middleware::CurrentAttributes`.

### `PoisonPill` — not a chain middleware

`Wurk::Middleware::PoisonPill` lives in the middleware directory but is
**never registered on either chain**. It's a module driven directly by the
reliable-fetch reaper / `bulk_requeue` paths via
`PoisonPill.track!(payload, queue:)`.

Each recovery of a job out of a dead process's private list `INCR`s
`super_fetch:recovered:<jid>` (72h TTL — wire-compatible with Sidekiq Pro's
tooling). At `RECOVERY_THRESHOLD` (3) the payload is moved to the dead set,
`jobs.poison` is emitted, and callbacks fire. `track!` returns `:poison` or
`:recovered`.

```ruby
# config/initializers/wurk.rb
Wurk::Middleware::PoisonPill.on_poison do |pill|
  Bugsnag.notify("poison pill: #{pill[:klass]} #{pill[:jid]} x#{pill[:count]}")
end
```

`on_poison` callbacks receive a Hash `{jid:, klass:, count:, queue:}`. The Pro
`config.super_fetch! { |jobstr, pill| … }` callback also fires on every
`track!` — with `nil` for the second argument on plain recovery, and a
`PoisonPill::Pill` struct (`.jid` / `.klass` / `.count` / `.queue`) on the kill
path. Callback exceptions are caught and routed to the configured error
handlers. Introspection: `PoisonPill.recovery_count(jid)`, `PoisonPill.clear!(jid)`.

---

## Interaction with retries, batches, and unique jobs

The server chain sits **inside** the retry onion. `Wurk::Processor#dispatch`
builds it as: job logger → `retrier.global` → job logger → stats → profiler →
reloader → instantiate → `retrier.local` → **server middleware chain** →
`perform`. Consequences:

- **An exception you raise from middleware is a job failure** and is booked as a
  retry by `JobRetry`, exactly as if `perform` had raised.
- **Returning without yielding is a clean exit.** No retry, no failure count,
  the unit of work is acked.
- **`Wurk::JobRetry::Skip`** (and its subclasses, e.g.
  `Wurk::Limiter::Rescheduled`) is the "I already handled this job — ack it, book
  nothing" signal. `Processor#process` rescues `JobRetry::Handled` and acks.
  Raise `Skip` when your middleware has re-enqueued the job itself.
- **`Wurk::Shutdown`** must propagate. If you `rescue Exception` and swallow it,
  the unit of work gets acked during shutdown and the job is lost — the whole
  point of reliable fetch is that an unacked payload survives in the private
  list.

Batches are visible in the ordering. `Batch::ServerMiddleware` is registered
**before** `Expiry` and `Limiter`, so batch is the outer onion and those two are
inner. That is why:

- An expired job (which *returns*) unwinds outward through batch's `yield`, so
  `ack_success` still runs and it counts as a batch success.
- A rate-limited job **raises** `Rescheduled` instead of returning, because a
  plain return would make batch ack success for a job that never ran. Batch
  rescues `JobRetry::Handled` and `Job::Interrupted` and re-raises them
  untouched — acking neither success nor failure.

If you insert middleware **outside** `Batch::ServerMiddleware` (via `prepend` or
`insert_before`), a skip-by-return in your middleware will bypass batch
accounting entirely and the batch will never complete. Register inside it
(`add`, or `insert_after Wurk::Batch::ServerMiddleware`) unless you specifically
need the outer position.

Unique jobs are a two-chain protocol: `Unique::ClientMiddleware` does
`SET NX EX` on the lock key and returns `nil` (halting the push) when another
jid holds it; `Unique::ServerMiddleware` releases it — before `perform` for
`unique_until: :start`, after a successful return for the default `:success`,
which is why a raising job keeps its lock until the TTL. Client middleware
registered **after** the unique middleware never runs for a dropped duplicate.

---

## Job-hash parsing and performance

The processor parses the payload once, eagerly:
`Processor#parse_or_kill` calls `Wurk.load_json(jobstr)` before the dispatch
onion, and malformed JSON goes straight to the dead set. Server middleware
therefore always receives a fully materialized `job` hash — there is no lazy
`args` wrapper to force, and no cost to reading `job['args']`.

What that means for authors: the hash is real, mutable, and shared by the whole
chain. Mutating `job['args']` in middleware changes what `perform` receives —
`Wurk::Encryption::ServerMiddleware` decrypts the last argument exactly this
way. Mutating it in *client* middleware changes what is written to Redis.

The cost you control is per-job allocation. `Chain#retrieve` instantiates every
registered middleware **on every job** — that's what makes middleware
thread-safe by construction, and it's why the chain stores ctor args rather than
a live object. Keep `initialize` trivial: no Redis calls, no file IO, no
`Rails.application.config` walks. Hoist expensive constants to the class level,
and prefer a cheap early `return yield` guard over work that only some jobs
need. The built-ins are all written this way.

---

## Gotchas

- **Client middleware runs again on retry and on scheduled promotion.** Anything
  that must be captured once at enqueue time needs `||=`, not `=`.
- **Wrong arity fails at runtime, not at registration.** `add` accepts any
  class. A three-argument `call` on the client chain raises `ArgumentError`
  inside the first push.
- **Returning falsy from client middleware silently drops the job.** Always
  return `yield`'s value. `def call(...) = yield` is fine; a trailing
  `logger.info(...)` that returns `nil` is not.
- **`add` removes before appending.** Calling `add(X)` on an already-registered
  `X` moves it to the end of the chain. Use `exists?` if you mean "register
  once, keep position" — that's what `Wurk::Unique` and `Wurk::Encryption` do.
- **`insert_before`/`insert_after` with an unregistered anchor silently fall
  back** to index 0 and the end of the chain respectively. They don't raise, so
  a typo'd class name produces a wrong-position middleware, not an error.
- **`chain.clear` removes the built-ins too** — including `InterruptHandler`,
  batch accounting, and metrics. Prefer `remove(klass)`.
- **`Wurk::Testing` uses a separate chain.** Inline test mode
  (`Sidekiq::Testing.inline!`) invokes `Wurk::Testing.server_middleware`, which
  starts **empty** — the production server chain does not apply. Register test
  middleware with `Sidekiq::Testing.server_middleware { |c| c.add … }`.
- **`Wurk::Client.new(chain:)`** lets you construct a client with a custom
  chain, and `client.middleware { |c| … }` yields a *duplicate* (leaving the
  original untouched) while `client.middleware` with no block returns the live
  chain.
- **Don't hold a Redis connection in an instance variable.** Instances are
  per-job, but the underlying pool is per-fork; check out through `redis_pool` /
  `redis` each time.

---

## Related

- [Migrating from Sidekiq](migrate-from-sidekiq.md) — the drop-in alias contract.
- [Running Wurk](running.md) — capsules, concurrency, and the boot sequence.
- [Active Job](active-job.md) — where the adapter sits relative to these chains.
