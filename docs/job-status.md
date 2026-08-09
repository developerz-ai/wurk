# Job status, progress & results (`Wurk::Status`)

> **Wurk-only extra — not a Sidekiq surface.** Stock Sidekiq loses a job the
> moment it finishes: no lookup by jid, no progress outside batches, no record
> of what `perform` returned. If you migrate back to plain Sidekiq you lose
> first-party job status/progress/result lookup entirely — you'd need the
> third-party `sidekiq-status` gem, and even then you'd lose stored return
> values, since that gem doesn't capture them.

`Wurk::Status` is opt-in, per worker class, and additive: a class that never
sets `track: true` writes nothing, reads nothing, and allocates nothing extra
for it — see [Zero cost when untracked](#zero-cost-when-untracked) for the
proof.

## Contents

- [Opting in](#opting-in)
- [Configuration](#configuration)
- [Zero cost when untracked](#zero-cost-when-untracked)
- [State machine](#state-machine)
- [Reading a status](#reading-a-status)
- [In-job progress](#in-job-progress)
- [Coalescing](#coalescing)
- [Result capture](#result-capture)
- [Interrupted, retrying, dead — not failed](#interrupted-retrying-dead--not-failed)
- [Encryption interaction](#encryption-interaction)
- [Coexistence with `sidekiq-status`](#coexistence-with-sidekiq-status)
- [See also](#see-also)

## Opting in

Set `track: true` in `sidekiq_options` — the same DSL entry point every other
per-class option (`retry:`, `unique_for:`, `collapse:`, …) goes through:

```ruby
class ImportJob
  include Wurk::Worker

  sidekiq_options track: true

  def perform(file_id)
    status.at(0, total_rows, 'starting')
    # ...
    status.at(row, total_rows)
  end
end
```

ActiveJob classes get the same DSL via `Wurk::Job::Options`, mixed into the
`:wurk` / `:sidekiq` queue adapter's job wrapper:

```ruby
class ImportJob < ApplicationJob
  sidekiq_options track: true
end
```

`track:` accepts only `true` or `false` — a class-level `sidekiq_options
track: true` or a per-push `set(track: true)` both go through the same
validator (`Wurk::JobUtil.validate_track!`), and anything else (a string, a
symbol, `nil` treated as "maybe") raises `ArgumentError` at the point it was
set rather than silently tracking — or silently not tracking — every job of
the class.

Tracking rides on the job payload itself, not the class definition at read
time: a job already enqueued before you flip `track: true` on keeps running
untracked to completion, instead of half-tracking a job whose `enqueued` row
was never written.

## Configuration

Two knobs, both on `Wurk.configuration`:

| Option | Default | Meaning |
|---|---|---|
| `status_ttl` | `1800` (30 minutes, `Wurk::Keys::STATUS_TTL`) | Seconds a `status:<jid>` row lives. Re-stamped on every write — an abandoned row (a job that crashed the process, or a swarm that never got the terminal write) disappears on its own. No sweeper, no unbounded key growth. |
| `status_retention` | `nil` | How long a `complete` row outlives the job that wrote it. `nil` (default) means a completed row expires on the same `status_ttl` clock as every other write. `0` deletes the row the instant the job succeeds — today's Sidekiq behavior, a succeeded job leaves nothing. Any other integer sets its own TTL, independent of `status_ttl`, so you can keep succeeded jobs around longer than in-flight ones. |

```ruby
Wurk.configure_server do |config|
  config.status_ttl = 1.hour.to_i
  config.status_retention = 1.day.to_i
end
```

`status_retention` only bends the lifetime of a `complete` row. Failed and
dead jobs are already findable in the `retry` and `dead` sets, so their status
rows follow the plain `status_ttl` clock regardless of retention.

## Zero cost when untracked

A class that never sets `track: true` pays nothing beyond one Hash lookup and
a `yield` in the server middleware. This isn't a claim — it's asserted by
command count in `test/unit/status_enqueue_test.rb`:

- An untracked single push costs exactly the two commands it always has:
  `SADD queues` + `LPUSH queue:<name>`.
- An untracked bulk push costs the same two commands per group, regardless of
  batch size.
- An untracked batched (`Sidekiq::Batch`) push costs exactly one command (the
  `batch_push` EVALSHA), same as before this feature existed.

`Client#track_enqueued` only resolves `status_ttl` from configuration and only
calls `Wurk::Status.enqueued` when a given job's payload has `track` set —
an app that never opts in never reads the status configuration at all.

For a job that *is* tracked, the enqueue-time write rides the pipeline the
client already has open for the queue write — `HSET` + `EXPIRE` appended
alongside the `SADD`/`LPUSH`, not a round trip of its own. A tracked bulk push
of N jobs is still one round trip: `SADD + LPUSH + 2 commands per tracked
job`, all in the same pipeline.

## State machine

```text
enqueued ──▶ running ──┬─▶ complete
                       ├─▶ interrupted
                       └─▶ failed ──┬─▶ retrying   (next attempt writes running again)
                                    └─▶ dead
```

The exact state strings (`Wurk::Status::STATES`):

```ruby
%w[enqueued running complete failed interrupted retrying dead]
```

- **`enqueued`** — written by the client at push time, only for an immediate
  (non-scheduled) push. A scheduled job sits in the ZSET for minutes or days —
  well past the default TTL — so an `enqueued` row would expire before the job
  ever ran; there's no `scheduled` state to tell that truth with. Its first
  row is the `running` one the server middleware writes when it's eventually
  fetched.
- **`running`** — written by the server middleware the moment an attempt
  starts, re-deriving every timestamp from the job payload (so it's correct
  even for a job pushed by something that never wrote an `enqueued` row —
  stock Sidekiq, a raw `LPUSH`, a re-push from the dashboard).
- **`complete`** — `perform` returned normally; its return value is captured
  (see [Result capture](#result-capture)).
- **`interrupted`** — a cooperative stop (`Wurk::Job::Interrupted`, the
  `IterableJob` deadline/shutdown path). Not a failure.
- **`failed`** — the attempt raised. Written the instant it raises, before
  it's known whether the job will retry or die.
- **`retrying`** — written one frame further out, once `Wurk::JobRetry` has
  actually scheduled the next attempt on the retry ZSET. `attempt` on the row
  is bumped to reflect the failed attempt.
- **`dead`** — written by the shared death-handler path: retries exhausted,
  `sidekiq_retry_in` returning `:discard`, `dead: false`, or a poison-pill
  kill all funnel through here, the same registration shape as
  `Batch::DeathHandler`.

## Reading a status

```ruby
record = Wurk::Status.get(jid)
# => nil if the jid is unknown, the class isn't tracked, or the TTL lapsed

record.state          # "running", "complete", "failed", ...
record.queue
record.job_class       # `class` on the wire; `job_class` because `class` isn't a legal reader name
record.progress        # Integer or nil — nil means "never reported", not 0
record.total
record.message
record.attempt
record.enqueued_at     # epoch seconds, Float
record.started_at
record.finished_at
record.result          # decoded JSON return value, or the raw truncated head — see below
record.result_truncated?
record.result_withheld?
record.error_class
record.error_message
record.to_h             # the same shape the HTTP API and dashboard serve
```

`Wurk::Status.delete(jid)` removes a row outright and returns `true` when one
actually existed.

Both accept `pool:` to run against a specific `Wurk::RedisPool` rather than
the process-wide one.

## In-job progress

The server middleware hands a tracked worker a `Wurk::Status::Progress`
handle through `status` (a plain attr on `Wurk::Worker`, `nil` for an
untracked class — call it as `status&.at(...)` if you want the same worker
code path to run either way):

```ruby
def perform(file_id)
  rows.each_with_index do |row, i|
    import(row)
    status.at(i, rows.size, "importing row #{i}")
  end
end
```

- `status.at(num, total = nil, message = nil)` — reports position. `total`
  and `message` are optional and sticky: pass them once, and later bare
  `at(n)` calls keep whatever was last set. Returns `num`, so it can wrap an
  existing counter expression.
- `status.message(text)` — reports a step description without moving the
  counter.
- `status.flush` — forces out whatever `at`/`message` buffered since the last
  write, *bypassing* the coalescing window below; returns `true` when something
  was actually written, `false` when there was nothing buffered to write.

## Coalescing

Progress writes are rate-limited so a tight loop calling `at()` per row can't
flood Redis: at most one write lands per **5-second window**
(`Wurk::Status::Progress::INTERVAL`, mirroring `IterableJob`'s own
`STATE_FLUSH_INTERVAL` — a job checkpointing its cursor and a job reporting
progress are the same traffic problem). The newest unwritten values are
buffered in memory; only the most recent `at`/`message` call inside a window
survives. The first report is never delayed — a job that calls `at` once,
early, is visible immediately.

The window governs `at`/`message` only. `status.flush` is the deliberate
escape hatch and ignores it: an `at` followed by an explicit `flush` writes
straight through, even twice inside the same 5 seconds. That is the point — a
milestone worth interrupting a batch for shouldn't wait on a rate limiter — but
it does mean a `flush` in the same tight loop you were protecting hands the
rate limit right back. Flushing with nothing buffered costs no round trip and
returns `false`.

Nothing is lost at the end of a run: the server middleware's terminal write
(`complete`/`interrupted`/`failed`) drains whatever the handle buffered and
folds it into that same write — a job's last reported position rides along on
the terminal transition rather than costing a round trip of its own. A
caller with no terminal write of its own (e.g. calling into `Progress`
directly, outside a job) should call `#flush` to force the last buffered
value out.

The handle is monotonic-clock based, not wall-clock: a job holding it for
hours won't skip or storm writes because NTP stepped the clock. It's also not
thread-safe — one handle belongs to one job execution on one thread, same
contract as `IterableJob`'s cursor state.

## Result capture

The server middleware records `perform`'s own return value on the `complete`
row, JSON-encoded (JSON only — never MessagePack, per the wire-compat rules).
`nil` is the overwhelmingly common return value and answers nothing a missing
field doesn't, so it isn't stored at all.

The serialized result is capped at **8 KB**
(`Wurk::Middleware::Status::MAX_RESULT_BYTES`) — a job that returns an
ActiveRecord relation costs Redis 8 KB, not a table dump. Past the cap, the
head of the JSON is kept (cut on a byte boundary, UTF-8-scrubbed so a
multi-byte character never gets split) and the `result_truncated` field is
set to `"1"`. `Record#result_truncated?` reflects it; when truncated,
`Record#result` returns the raw head string rather than trying to
`JSON.parse` a JSON fragment.

A value that can't be serialized at all (raises on `to_json`) is dropped
silently — a stored result is a record of the job, never a reason to fail an
otherwise-successful attempt — and the error is reported through
`Wurk.configuration.handle_exception`.

Error text gets the same treatment on `failed`/`dead` rows, capped at **1 KB**
(`MAX_ERROR_BYTES`) — so a parser whose exception message quotes the whole
offending document doesn't store the document.

## Interrupted, retrying, dead — not failed

The rescue taxonomy deliberately separates a handled stop from a real failure,
mirroring `Batch::ServerMiddleware`:

- A cooperative stop (`Wurk::Job::Interrupted` — `IterableJob`'s deadline or
  shutdown path) writes `interrupted`, never `failed`. `interrupted` promises
  nothing about resumption; it's simply not a failure.
- A retry that's been handled elsewhere in the chain
  (`Wurk::JobRetry::Handled`) leaves the row exactly as `running`, with
  whatever progress was buffered flushed onto it — the job has been put back
  on a queue and will run again, so nothing terminal is written yet.
  `retrying` itself is written later, once `JobRetry` has confirmed the retry
  actually landed on the ZSET, and `dead` only from the shared death-handler
  path once every route to "this job doesn't come back" (retries exhausted,
  `:discard`, `dead: false`, a poison-pill kill) has funneled through it.
- A raised `StandardError` writes `failed` immediately — that much is always
  true the instant an attempt raises, before it's known whether a retry
  follows.

One documented caveat: a `Wurk::Limiter::OverLimit` raised inside a job body
unwinds through this middleware *before* `Limiter` (further out in the chain)
converts it into a reschedule — so a rate-limited job books `failed` for an
attempt it never really ran. This is pinned behavior (see
`test/unit/metrics_history_test.rb`), shared with `Metrics::History`, and
depends on a chain-ordering decision that hasn't been made yet.

## Encryption interaction

A worker that sets both `encrypt: true` (see `docs/target/sidekiq-ent.md`
§4) and `track: true` gets its full lifecycle tracked — `running`,
`failed`/`retrying`/`dead` timestamps and error fields all write normally —
but its **result is never stored**. `encode_result` checks
`withhold_result?(job)` (which reads `job['encrypt']`) before serializing
anything; if the job declared its args a secret, the return value is dropped
and the row gets `result_withheld: "1"` instead of a `result` field.

Why withhold rather than encrypt the row: encrypting just the result would
mean every reader of a status row — dashboard, HTTP API, a chain piping the
result onward — needs the crypto key, and the crypto contract is scoped to
the last positional argument, not to arbitrary stored data. Withholding the
result is a one-line answer that doesn't leak plaintext back in beside args
Wurk went out of its way to keep out of Redis.

`Record#result_withheld?` distinguishes "the job returned nothing" from "the
job returned something Wurk refused to keep in plaintext" — a job that
returns `nil` while `encrypt: true` is set is *not* flagged as withheld,
because there was nothing to withhold. The decision is made from the
payload's own `encrypt` flag, not from whether crypto happens to be
configured in the process that ran the job — including the documented
silent-no-op case where `encrypt: true` is set but `Wurk::Encryption.enable`
was never called and the args went to Redis in cleartext anyway; the result
is still withheld either way.

## Coexistence with `sidekiq-status`

`Wurk::Status` is deliberately **not** aliased as `Sidekiq::Status`, and its
Redis key (`status:<jid>`) is deliberately **not** `sidekiq:status:<jid>` —
that's the third-party [`sidekiq-status`](https://github.com/utgarda/sidekiq-status)
gem's own row shape (`Sidekiq::Status.status_key`). A host running both at
once — migrating off `sidekiq-status` gradually, or keeping it for a plugin
that depends on its specific API — gets two independent, non-colliding
tracking systems rather than one shadowing the other with different
semantics. `bin/rake test:ecosystem` exercises the `sidekiq-status` gem's own
suite against Wurk to keep this true.

## See also

- [`docs/plans/2026/08/07/101-beyond-sidekiq/06-job-status-results.md`](plans/2026/08/07/101-beyond-sidekiq/06-job-status-results.md) — the design doc this feature was built from.
- [`docs/api-http.md`](api-http.md) — `GET /jobs/:jid` serves this same data over HTTP, scoped to `read`, `404 job_not_found` for an untracked, unknown, or TTL-expired jid.
- [`docs/flows.md`](flows.md) — chains pipe a step's stored `Wurk::Status` result into the next job's args.
