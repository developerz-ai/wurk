# Rate limiting

Wurk ships the Sidekiq Enterprise rate limiters — free, in the same gem, no
flag. A limiter is a small object you construct once and call with a block:

```ruby
STRIPE = Sidekiq::Limiter.concurrent("stripe", 50)

class ChargeJob
  include Sidekiq::Job

  def perform(order_id)
    STRIPE.within_limit { Stripe::Charge.create(...) }
  end
end
```

All state lives in Redis and every acquire is a single Lua script, so the limit
holds across processes, forks and hosts. **All timing inside Lua comes from
Redis `TIME`**, not from the calling host's clock — client clock skew cannot
push a limiter over its limit.

`Sidekiq::Limiter` is an alias of `Wurk::Limiter` (and `Sidekiq::Limiter::OverLimit`
of `Wurk::Limiter::OverLimit`). Existing Enterprise code keeps working on the
one-line gem swap; use either name.

---

## The five types

| Type | Bounds | Pick it when | Constructor |
|---|---|---|---|
| `concurrent` | How many blocks may run **at the same time** | You have N connections/seats/licenses and care about simultaneity, not rate | `concurrent(name, limit, wait_timeout: 5, lock_timeout: 30, policy: :raise, backoff: nil, ttl: 7776000)` |
| `bucket` | Operations per **calendar period**, reset at the top of the unit | The remote API says "1000 per hour", counted per clock hour | `bucket(name, count, interval, wait_timeout: 5, backoff: nil, ttl: 7776000, reschedule: 20)` |
| `window` | Operations per **sliding window** ending now | The remote API says "60 in any 60 seconds" — no boundary to burst across | `window(name, count, interval, wait_timeout: 5, backoff: nil, ttl: 7776000, reschedule: 20)` |
| `leaky` | Burst size **plus** a steady drain rate | You may burst up to N but must average out to a fixed rate | `leaky(name, bucket_size, drain, wait_timeout: 5, backoff: nil, ttl: 7776000)` |
| `points` | Non-uniform **cost** per operation | Calls differ in weight (API "credits", token budgets) | `points(name, initial_points, refill_per_second, backoff: nil, ttl: 7776000)` |
| `unlimited` | Nothing | Tests, or swapping a limiter out at a call site | `unlimited(*ignored, **ignored)` |

`ttl` (default `90 * 24 * 3600`) is the Redis TTL on the limiter's keys, refreshed on
every use. **Values under `86_400` raise `ArgumentError`** — a metadata hash that
expires mid-job orphans slots.

### concurrent

```ruby
DB = Sidekiq::Limiter.concurrent("legacy-db", 5, lock_timeout: 60, wait_timeout: 10)
DB.within_limit { LegacyDB.query(...) }
```

- A slot is a member of a ZSET scored with its expiry (`now + lock_timeout`).
  Acquire first evicts expired slots, then adds yours if there's headroom.
- `lock_timeout` is the safety net for a crashed worker: after that many
  seconds the slot is reclaimed even if the block never finished. Set it above
  your realistic worst-case block duration, or you'll run over the limit.
- `policy: :ignore` **skips the block silently** when no slot is free —
  `within_limit` returns `nil`, nothing is raised, nothing is rescheduled.
  `policy: :raise` (the default) raises `OverLimit` after `wait_timeout`.
- Only `concurrent` keeps metric counters (see [Introspection](#introspection)).

### bucket

```ruby
MAIL = Sidekiq::Limiter.bucket("sendgrid", 1000, :hour)
MAIL.within_limit { SendGrid.deliver(...) }
```

- `interval` must be one of `:second :minute :hour :day` — a **raw Integer
  raises `ArgumentError`**, because "reset at the boundary" needs a unit. The
  interval is validated in the constructor, so a typo fails at boot.
- The counter is keyed by epoch index (`now / interval`) and resets by rolling
  onto a new key, not by decrementing. Two full buckets back-to-back across a
  boundary means a `2 × count` burst — that's what `window` avoids.
- `within_limit(used: n)` charges `n` units atomically (default `1`); a call is
  admitted only if the *whole* charge fits.

### window

```ruby
API = Sidekiq::Limiter.window("partner-api", 60, :minute)
API.within_limit { Partner.get(...) }

FAST = Sidekiq::Limiter.window("burst", 5, 10)   # 5 per any 10 seconds
```

- `interval` accepts the same symbols **or a raw Integer of seconds**.
- Backed by a ZSET of timestamps, trimmed to `now - interval` on every acquire.
  No boundary to burst across.
- `within_limit(used: n)` charges `n` entries in one atomic script.

### leaky

```ruby
SMS = Sidekiq::Limiter.leaky("twilio", 100, :minute)   # burst 100, drains 100/min
SMS.within_limit { Twilio.send(...) }
```

- `bucket_size` is the burst capacity; `drain` is the period over which a full
  bucket drains, as a symbol (`:second :minute :hour :day`) or a positive
  Integer count of seconds. The drip rate is `bucket_size / drain` per second.
- Each admitted call adds 1 to the level; the level leaks continuously.
- A non-positive `bucket_size` or `drain` raises `ArgumentError` rather than
  producing a silent zero rate.

### points

```ruby
LLM = Sidekiq::Limiter.points("anthropic-tokens", 100_000, 500)  # cap, refill/sec

LLM.within_limit(estimate: 2_000) do |handle|
  resp = Anthropic.complete(...)
  handle.points_used(resp.total_tokens)   # settle up: refund or over-charge
end
```

- `estimate:` is **required** and must be positive; otherwise `ArgumentError`.
- The block is yielded a handle. `handle.points_used(actual)` applies the
  signed delta `estimate - actual` — positive refunds, negative charges more.
  The balance is clamped to `[0, initial_points]`. Calling it is optional.
- **`points` never waits.** If the refilled balance is below `estimate` it
  raises `OverLimit` immediately; it has no `wait_timeout`.

### unlimited

```ruby
worker.limiter = Sidekiq::Limiter.unlimited
```

Accepts any arguments and any `within_limit` keywords, runs the block
unconditionally, and yields a zero-cost handle to `points`-style blocks so a
swap needs no call-site change. It touches Redis not at all — it never
registers, so it does not appear in the dashboard.

---

## `within_limit` semantics

```ruby
limiter.within_limit { ... }                          # concurrent, bucket, window, leaky
limiter.within_limit(used: 3) { ... }                 # bucket, window only
limiter.within_limit(estimate: 200) { |handle| ... }  # points only
```

A block is required — `within_limit` without one raises `ArgumentError`.

| Type | On exhaustion | Poll interval | Timeout |
|---|---|---|---|
| `concurrent` | retry loop until a slot frees | 50 ms | `OverLimit` past `wait_timeout` (or return `nil` under `policy: :ignore`) |
| `bucket` | retry loop, sleeping toward the next boundary | ≤ 50 ms | `OverLimit` past `wait_timeout` |
| `window` | retry loop until the oldest entry slides out | 500 ms | `OverLimit` past `wait_timeout` |
| `leaky` | retry loop while the bucket drains | 50 ms | `OverLimit` past `wait_timeout` |
| `points` | no wait at all | — | `OverLimit` immediately |

The wait blocks the calling **thread** — it holds a worker thread, not a
process. `wait_timeout: 0` means "fail immediately"; the default is `5`
seconds. The deadline covers only the acquire, never the block itself.

`within_limit` returns whatever the block returns. On block exit the
`concurrent` slot is always released (in an `ensure`); the other types decay on
their own clock and have nothing to release.

---

## `OverLimit` and the retry system

```ruby
Sidekiq::Limiter::OverLimit < StandardError
  #limiter   # the limiter object that refused
  #job       # the job hash in flight (set by the server middleware)
```

The message reads `limit 'stripe' (concurrent) reached`.

**Inside a job you normally do nothing.** `Wurk::Limiter::ServerMiddleware` is
registered in the default server chain, catches `OverLimit`, and:

1. Increments `job['overrated']` on the job hash.
2. If the limiter's `reschedule` is `0`, re-raises — the job goes through the
   normal retry/dead pipeline like any other error.
3. Otherwise re-pushes the job onto the **same queue** at `Time.now + backoff`
   and raises an internal skip signal, so the run counts as neither success nor
   failure: no retry is booked, no failure is recorded, and an enclosing batch
   acks nothing.
4. When `job['overrated']` reaches the `reschedule` cap (default `20`), the
   **poison brake** fires: the job goes straight to the dead set with
   `error_message` prefixed `rate_limited:`, death handlers run, and the
   `jobs.rate_limited` StatsD counter is bumped. It is not also retried.

The backoff is `limiter.options[:backoff]` if set, else
`Sidekiq::Limiter.config.backoff`, else the default
`(300 * overrated) + rand(300) + 1` seconds — i.e. escalating five-minute steps
with jitter. A proc receives `(limiter, job_hash, exception)` and returns
seconds.

Only `bucket` and `window` take a `reschedule:` keyword. `concurrent`, `leaky`
and `points` have no such option, so the middleware applies the default cap of
20 to them.

### Global config

```ruby
# config/initializers/wurk.rb
Sidekiq::Limiter.configure do |config|
  config.backoff = ->(_limiter, job, _exc) { 60 * job["overrated"] }
  config.redis   = { size: 10, url: "redis://limiter:6379/0" }
  config.errors << MyApp::UpstreamRateLimited
end
```

| Setting | Default | Effect |
|---|---|---|
| `backoff` | `(300 * overrated) + rand(300) + 1` | Fallback delay proc for limiters with no own `backoff:` |
| `redis` | `nil` (shares `Wurk.redis_pool`) | A `Hash` (`{ size:, url:, … }`, size defaults to 10) or a built `Wurk::RedisPool`. Dedicated pool so limiter traffic can't starve fetching |
| `errors` | `[OverLimit]` | Extra exception classes the middleware treats exactly like `OverLimit` |

`config.errors` is the hook for third-party throttling: push your HTTP client's
"429" exception in and any job that raises it gets the same
increment-and-reschedule treatment. Such an exception carries no `limiter`, so
the default cap and the global `backoff` apply.

All three are re-read on every job, so changing them at runtime takes effect
immediately.

---

## Global concurrency vs the per-key limiters

Two different questions, easy to reach for the wrong one:

| Question | Reach for |
|---|---|
| "At most N jobs from **this queue** should ever be running, across the whole cluster, no matter how many worker processes are up" | `config.global_concurrency` |
| "Calls against **this external resource** (an API, a DB, a seat pool) must stay under a rate or a concurrency limit, and the jobs making those calls may be spread across several queues, or several classes on the same queue" | `Sidekiq::Limiter` (this page) |

`config.global_concurrency` is a **fetch-side** gate — it caps how many jobs
of a queue are *checked out and running* at once, enforced before a job is
even popped off Redis:

```ruby
Wurk.configure_server do |config|
  config.global_concurrency = { "critical" => 20, "reports" => 2 }
end
```

- Capacity, not a rate: a `window`/`bucket` limiter answers "how many per
  second"; `global_concurrency` answers "how many at once". There is no
  waiting or rescheduling built in — a queue at its cap is simply skipped on
  that fetch pass and retried on the next one, so throughput settles at
  whatever the cap allows rather than backing off exponentially.
- Crash-safe by construction: each hold is a ZSET member with an expiry, so a
  `SIGKILL`ed worker's slot returns on its own; nothing to reconcile or reap
  by hand ({Wurk::QueueSlot}).
- Zero cost when unset — `global_concurrency: {}` (the default) skips the cap
  check on every fetch, so an app that never configures this pays nothing for
  it (verified in `bench/command_count.rb`).
- Scoped to a **queue name**, not a resource or a job class. If two different
  classes share a queue, they share the cap.

A `Sidekiq::Limiter` is the right tool when the constraint lives on the
*resource* your job calls, independent of which queue or class it runs under
— a Stripe rate limit, a database connection ceiling, a third-party API's
requests-per-minute. It runs inside `perform`, so it can wait, back off, or
reschedule around a busy limiter rather than just skipping a fetch pass; and
because its identity is a name you pick, not a queue, jobs on different
queues (or written in different classes) can share one limiter.

The two compose freely and answer different halves of the same "too much load
at once" problem — a queue can carry a `global_concurrency` cap *and* have its
jobs call into a `Sidekiq::Limiter.concurrent` around the one shared resource
they all hit.

---

## Naming and Redis keys

The name is the Redis key suffix, so it is also the unit of sharing. It must
match `/\A[\w\-:.\#@]+\z/` — word characters plus `- : . # @`. Anything else
(spaces, slashes) raises `ArgumentError`.

Interpolation is the intended way to get per-tenant limits:

```ruby
def perform(account_id)
  Sidekiq::Limiter.window("shopify-#{account_id}", 40, :second).within_limit do
    Shopify.call(...)
  end
end
```

| Key | Type | Contents |
|---|---|---|
| `lmtr:{name}` | HASH | Metadata: `type`, `options` (JSON), `fingerprint` |
| `lmtr-list` | SET | Every registered limiter name — what the dashboard lists |
| `lmtr-cs:{name}` | ZSET | `concurrent`: held slots, score = expiry epoch |
| `lmtr-stats:{name}` | HASH | `concurrent`: metric counters |
| `lmtr-b:{name}:{epoch}` | STRING | `bucket`: counter for one period |
| `lmtr-w:{name}` | ZSET | `window`: timestamps inside the interval |
| `lmtr-l:{name}` | HASH | `leaky`: `{ level, last }` |
| `lmtr-p:{name}` | HASH | `points`: `{ points, last }` |

Every key carries `EXPIRE ttl`, refreshed on use, so an interpolated name that
goes quiet cleans itself up. Constructing a limiter writes its metadata and
adds the name to `lmtr-list`; a limiter for a tenant you'll never see again
stays visible in the dashboard until its TTL lapses, or until you call
`#delete`.

`#fingerprint` is a SHA256 over `type | name | options`, so the dashboard can
group interpolated names that share a shape.

---

## Introspection

Every limiter answers the same shape:

```ruby
limiter.name       #=> "stripe"
limiter.type       #=> :concurrent
limiter.options    #=> { limit: 50, wait_timeout: 5, … }
limiter.size       #=> current usage (Integer, or Float for leaky/points)
limiter.status     #=> { used:, limit:, reset_at:, available?: }
limiter.reset      # clears state, keeps the limiter registered
limiter.delete     # clears state + metadata, removes it from lmtr-list
```

`reset_at` is epoch seconds (Float) or `nil` when the type has no clock-driven
reset: the next boundary for `bucket`, when the oldest entry leaves for
`window`, the soonest slot expiry for `concurrent`, when the drip/refill frees
room for `leaky`/`points`.

`concurrent#status` additionally merges its counters — `held`, `held_time`,
`immediate`, `waited`, `wait_time`, `overages`, `reclaimed`. `held`/`held_time`
count acquired slots and the seconds they were held, `immediate` counts acquires
that didn't wait, `waited`/`wait_time` those that did, `overages` holders that
outran `lock_timeout` (their slot was already gone when they released),
`reclaimed` slots evicted because they outlived `lock_timeout`.

Waiting past `wait_timeout` is *not* an overage — that raises `OverLimit` and is
counted per job in `overrated`.

---

## Using a limiter outside a job

From a controller, a rake task, or any non-job code there is **no server
middleware**, so nothing catches `OverLimit` and nothing reschedules. Handle it
yourself:

```ruby
class ChargesController < ApplicationController
  STRIPE = Sidekiq::Limiter.concurrent("stripe", 50, wait_timeout: 1)

  def create
    STRIPE.within_limit { Stripe::Charge.create(charge_params) }
    head :created
  rescue Sidekiq::Limiter::OverLimit
    head :too_many_requests
  end
end
```

Keep `wait_timeout` small in request paths — the wait blocks the web worker.
The usual answer is to not do the work inline at all: enqueue a job and let the
limiter reschedule it.

---

## Dashboard

The dashboard has a **Limiters** page (left rail, `/limiters`) backed by
`GET /api/limiters`. It lists every name in `lmtr-list` with type, `used`,
`limit`, a usage bar, an available/exhausted badge, and — for `concurrent` —
the metric counters. It paginates and takes a `substr` name filter, and each
row has a **Reset** button (`POST /api/limiters/:name/reset`) that drops the
limiter's state and stats keys while keeping the row.

Reset is a mutation, so it's hidden in read-only mode and gated by the
`authorization` hook like every other write — see
[Authentication & authorization](authentication.md).

Two caveats about the dashboard Reset: it clears the fixed state keys, but a
`bucket` counter lives under an epoch-suffixed key, so use `limiter.reset` from
Ruby if you need to zero a bucket mid-period. And there is no Delete button —
`#delete` is Ruby-only.

---

## Gotchas

- **Limiters are cheap but not free to construct.** The constructor does a
  Redis round-trip (`SADD` + `HSET` + `EXPIRE`) to register itself. Hoisting
  one into a constant, as in the examples, is the right default; constructing
  per-tenant limiters inside `perform` is fine but pays that write each time.
  Pass `register: false` to the class constructor for read-only introspection.
- **Limiters don't compose.** There is no AND combinator. For "5/min AND
  100/hr", enforce the tighter bound and let the upstream API police the rest.
- **`concurrent` fairness is not guaranteed.** Waiters poll every 50 ms and the
  winner is whoever's poll lands first — under contention, latency is not
  ordered by arrival.
- **`lock_timeout` shorter than your work means over-admission.** The slot is
  reclaimed while your block still runs and another worker walks in; you'll see
  it as a rising `reclaimed` counter.
- **`bucket` bursts across boundaries.** A full bucket at 10:59:59 plus a full
  one at 11:00:00 is `2 × count` inside two seconds. Use `window` when the
  upstream limit is a rolling one.
- **Clock skew across app hosts still matters for `wait_timeout`.** The limiter
  state itself is safe — every Lua script reads Redis `TIME` — but the wait
  deadlines are measured on the calling host. Run NTP.
- **`policy: :ignore` silently drops work.** The block never runs and the job
  is acked as a success. Only use it for work that is genuinely optional.
- **Blocking a worker thread is real capacity.** A `wait_timeout` of 5 seconds
  on a saturated limiter means threads parked for 5 seconds. Prefer a short
  timeout plus the automatic reschedule over a long wait.

---

## Related

- [Migrating from Sidekiq](migrate-from-sidekiq.md) — the alias contract and
  what a swap changes.
- [Securing the dashboard & web extensions](dashboard.md) — the Limiters page
  and dashboard config.
- [Authentication & authorization](authentication.md) — gating the reset
  action.
