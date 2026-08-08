# 00 — Semantics sign-off: interrupted-run metrics + job-JSON key additions

> Part of [`overview.md`](overview.md). Blocks [`01-metrics-interrupted-job.md`](01-metrics-interrupted-job.md)
> (§1) and [`05-opentelemetry.md`](05-opentelemetry.md) / [`06-job-status-results.md`](06-job-status-results.md) /
> [`08-timeout-deadline.md`](08-timeout-deadline.md) (§2).
> No code. This file is the record of what was decided, what it costs, what the
> implementation is *required* to do, and what would reverse the decision. Mirrors
> [`docs/plans/2026/08/06/101-faster-than-sidekiq/00-semantics-signoff.md`](../../08/06/101-faster-than-sidekiq/00-semantics-signoff.md).

## Sign-off state

| # | Decision | Cost accepted | State |
|---|---|---|---|
| 1 | Interrupted run books `p` + `ms`, never `f` (both `Metrics::History` and `Metrics::Statsd`) | #394's "spurious failure" symptom flips to "phantom success" for the rare crash-before-resume case; documented below | **Accepted** |
| 2 | `traceparent`/`tracestate` (05), a status opt-in marker (06), `timeout`/`deadline` (08) become new top-level job-JSON keys, additive only | Every third-party consumer of the raw job hash (gems, log scrapers, custom middleware) now sees keys it doesn't recognize on jobs that opt in | **Accepted** |

---

## Decision 1 — Interrupted run books `p` + `ms`, never `f`

**Today.** `Metrics::History#call` (`lib/wurk/metrics/history.rb:65-86`) sets
`success = false` unless `yield` returns, then unconditionally calls
`record(klass, duration, success:)`. `Accumulator#add`
(`lib/wurk/metrics/accumulator.rb:34-40`) books exactly one of `p`/`f` off that
boolean and always adds `ms`. `InterruptHandler` self-prepends
(`lib/wurk/middleware/interrupt_handler.rb:46`), so it sits **outside**
`Metrics::History` in the chain — `Wurk::Job::Interrupted` propagates *through*
`History#call` before `InterruptHandler` (`:31`) catches it, re-pushes the job,
and converts it to `Wurk::JobRetry::Skip`. Net effect: one cooperative
interruption books a spurious `<klass>|f` today, then a second `<klass>|p` when
the job resumes and completes — issue [#394](https://github.com/developerz-ai/wurk/issues/394),
carried from `docs/plans/2026/07/31/101-leak-logic-perf-fixes/status.yml` as
**F13**. `Metrics::Statsd#call` (`lib/wurk/metrics/statsd.rb:145-165`) has the
identical shape: `success = false` unless `yield` returns, then
`finalize(success, duration, …)` emits `jobs.success` or `jobs.failure`
(`:191-196`) with `jobs.perform`/`jobs.perform_dist` gauges either way.

**Oracle, read verbatim.** `docs/target/sidekiq-free.md` does not pin the
interrupted case (per the plan's own note), so the oracle is upstream
`Sidekiq::Metrics::ExecutionTracker#track`
(`lib/sidekiq/metrics/tracking.rb`, fetched from `sidekiq/sidekiq@main`):

```ruby
def track(queue, klass)
  start = mono_ms
  time_ms = 0
  begin
    begin
      yield
    ensure
      finish = mono_ms
      time_ms = finish - start
    end
    track_time(klass, time_ms)
  rescue JobRetry::Skip
    # This is raised when iterable job is interrupted.
    track_time(klass, time_ms)
    raise
  rescue Exception
    @lock.synchronize {
      @jobs["#{klass}|f"] += 1
      @totals["f"] += 1
    }
    raise
  ensure
    @lock.synchronize {
      @jobs["#{klass}|p"] += 1
      @totals["p"] += 1
    }
  end
end
```

Three outcomes, read off the structure:

| Path | `p` | `f` | `ms` |
|---|---|---|---|
| Success | yes (outer `ensure`) | no | yes (`track_time` before the rescue clauses) |
| `JobRetry::Skip` (interrupted) | yes (outer `ensure`) | no | yes (`track_time`, explicit rescue arm) |
| Any other exception | yes (outer `ensure`) | yes | **no** — the `rescue Exception` arm never reaches the `track_time` call above it |

So upstream's own answer to both of the plan's blocking questions is explicit,
not inferred: an interrupted run books `p`, not `f`, and it books `ms`
identically to a clean success. `p` is unconditional in the outer `ensure` —
every execution that reaches `perform` at all counts as "processed",
success/failure/interruption alike. Only a genuine failure skips `ms`, and
Wurk does not reproduce that half — see "Required to hold" below.

**Decision — mirror the oracle exactly, not `Batch::ServerMiddleware`'s
"neither".** The plan's suggested option ("neither p nor f") models an
interruption as unobserved, matching `Wurk::Batch::ServerMiddleware`
(`lib/wurk/batch/server_middleware.rb:56`), which treats a skip/handled exit
as neither success nor failure for *batch* completion counting. That is the
right model for a batch's pending-count semantics, which has no third
bucket to spend. It is the wrong model here: the oracle has a real,
authoritative answer for *this exact* middleware, and the drop-in contract
means a Wurk dashboard graphing `p`/`f`/`ms` off the same bucket keys a
migrated-in-place Sidekiq install already wrote must count the same way
Sidekiq counts, not the way Wurk's own batch layer happens to count a
different kind of skip.

**What an operator observes.**

1. An interrupted `IterableJob` no longer inflates `<klass>|f` — #394 fixed.
2. It now shows up as `<klass>|p` at the moment of interruption, then a
   **second** `<klass>|p` when the resumed job completes. Two `p` increments
   for one logical job execution, exactly as upstream does it (upstream's
   `ensure` fires once per `track` call, and a resumed `IterableJob` calls
   `track` — i.e. runs the full middleware chain — a second time). `p` was
   never meant to equal "distinct jobs completed"; it already means
   "middleware chain executions that didn't blow up with a real exception,"
   which is what Sidekiq's own dashboard has always plotted.
3. `<klass>|ms` gets **two** entries summed for one logical job — the pre-
   interruption partial run's wall-clock plus the resumed run's. This matches
   upstream (`track_time` fires on every `Skip`) and is arguably more honest
   than crediting only the final segment: the job consumed real wall-clock
   time across both windows and both should count toward "how much time has
   FooJob cost."
4. **Residual risk, named rather than hidden.** If a process is hard-killed
   between the interruption's `track_time`/`p` bump and the re-push's `RPUSH`
   landing in Redis, the `p` increment can survive without the job ever
   resuming (in-memory accumulator, not yet flushed — same crash-drop window
   Decision 2 of the faster-than-sidekiq sign-off already accepted for all
   `Metrics::History` counters). That trades #394's "guaranteed spurious `f`"
   for a "rare, crash-only phantom `p`" — strictly better, since `p` is meant
   to include exactly this "didn't error" case and the window is the same
   best-effort one every other metrics write already lives in.

**Why `Metrics::Statsd` gets the identical fix despite no public oracle.**
Sidekiq Pro's statsd emitter (`docs/target/sidekiq-pro.md` §9) is closed
source — there is no upstream implementation to fetch. The free
`ExecutionTracker` is the closest available oracle for the *shape* of the
decision (process-vs-failure classification of an interrupted run), and
`Metrics::Statsd#call` is structurally the same middleware pattern
(`success` boolean set in a `begin`/`ensure`) with the same #394-shaped bug:
`jobs.failure` fires for an interruption today. Divergence between the two
Wurk emitters on the exact same event would itself be a bug (the plan's
overview names this explicitly: "settle both in one pass"). Absent a public
Pro oracle, symmetry with the just-verified free oracle is the best evidence
available, and is philosophically consistent (a dogstatsd `jobs.success`
counter should mean the same thing as a `j|p` Redis counter).

**Required to hold:**

- `Metrics::History#call` (`:65-86`): rescue `Wurk::Job::Interrupted` around
  the `yield`, re-raise **without** calling `record(..., success: false)`.
  Suggested shape:
  ```ruby
  def call(_worker, job, _queue)
    klass = job['class']
    started = monotonic_ms
    success = false
    begin
      result = yield
      success = true
      result
    rescue Wurk::Job::Interrupted
      success = true
      raise
    ensure
      duration = (monotonic_ms - started).round
      begin
        self.class.record(klass, duration, success:, redis_pool: redis_pool)
      rescue StandardError => e
        handle_error(e)
      end
    end
  end
  ```
  `success = true` on the interrupted path, not a third accumulator slot —
  `Accumulator#add`'s `[processed, failed, ms]` triple has no room for a
  third bucket, and the oracle's own model is "everything that isn't a real
  failure counts toward `p`." Do **not** widen `Accumulator` to a 3-slot
  outcome for this; that's a wire-format change to a struct other code reads
  positionally, for a distinction upstream itself doesn't keep past `p`/`f`.
- `Metrics::Statsd#call` (`:145-165`): same rescue, same `success = true`,
  so `finalize` emits `jobs.success` + both duration gauges, never
  `jobs.failure`.
- `ms`/`jobs.perform*` stay booked on the interrupted path exactly as they
  are today — no change needed there, since Wurk already books `ms`
  unconditionally (unlike upstream's asymmetric skip-on-failure), which
  already matches the oracle's treatment of the `Skip` arm specifically.
- A genuinely failed job (any exception other than `Wurk::Job::Interrupted`)
  is unaffected: still books `f`, still books `ms` (Wurk's existing symmetric
  `ms` behavior, a pre-existing and out-of-scope divergence from upstream's
  asymmetric one — not touched by this decision).
- `Limiter::Rescheduled` stays unrecorded, unchanged: it raises outside
  `Metrics::History`/`Metrics::Statsd` in the chain
  (`lib/wurk.rb:285-291`), never reaching either middleware. A regression
  test pins that ordering assumption per `01-metrics-interrupted-job.md` step 4.
- The two middlewares must agree on every path. A test asserts they emit the
  same classification for: success, `Wurk::Job::Interrupted`, a real
  exception, and (documented as unreachable) `Limiter::Rescheduled`.

**Spec position.** Not a parity divergence — this *closes* one. Recorded in
`docs/idea/parity-divergences.md` below as "resolved," matching #394's
existing carry-forward from the July status file.

**Reversal trigger.** Evidence that Sidekiq's dashboard semantics for `p`
diverged from the verbatim `ExecutionTracker#track` quoted above (a newer
Sidekiq version changing the rescue structure) — re-fetch the oracle before
reverting on complaint alone; "an interrupted job shows `p`" is the *correct*
behavior per this sign-off, not a bug to revert on sight.

---

## Decision 2 — Job-JSON top-level key additions are additive, follow the `TRANSIENT_ATTRIBUTES` contract, and need no strip-list entry

**Today.** `Wurk::JobUtil` (`lib/wurk/job_util.rb`) is the sole gate a job
hash passes through before it reaches Redis. Two things matter for this
decision:

- `validate` (`:25-34`) checks `class`/`args`/`at`/`tags`/`retry_for` by
  presence and shape. It has **no key whitelist** — an unrecognized top-level
  key is neither rejected nor stripped by `validate`.
- `TRANSIENT_ATTRIBUTES = %w[pool client_class]` (`:20`) is the **opposite**
  list: keys `finalize` (`:108-115`) deletes *before* the payload reaches
  `raw_push`, because they carry non-JSON values (a connection pool, a
  `Class`) that must never hit the wire. That list is for keys that never
  leave the enqueuing process, not for keys that ride along in the job hash.

The plan (05 OpenTelemetry `traceparent`/`tracestate`, 06 Status's opt-in
marker, 08 timeout/deadline's `timeout`/`deadline`) is the first time wurk
adds keys of the **other** kind: JSON-native values that *do* reach the wire
and *do* need to survive a stock-Sidekiq round trip.

**Precedent — the ecosystem already does this, and upstream already tolerates
it.** `sidekiq-cron` and `sidekiq-unique-jobs` — both exercised by
`bin/rake test:ecosystem` — add their own top-level job-hash keys today,
against real Sidekiq, with no coordination from upstream:

- `sidekiq-unique-jobs` writes `lock`, `lock_timeout`, `lock_expiration`,
  `unique_prefix`, `unique_args`, and `unique_digest` (or `lock_digest`,
  depending on version) onto every unique job's payload.
- `sidekiq-cron` writes a `cron`-derived key identifying the schedule that
  enqueued the job.

Neither gem's key survives `Sidekiq::JobUtil` rejection, because upstream's
own `validate`/`normalize_item` has the same shape as Wurk's: presence checks
on the keys it cares about, silent pass-through for everything else.
Sidekiq's `Processor` reads the keys it knows (`class`, `args`, `queue`,
`jid`, `retry`, …) and never round-trips through a full-key assertion, so an
unrecognized key is inert cargo, not a protocol violation. This is the
existing, ecosystem-proven mechanism the plan's three slices are riding, not
a new one — the census note in `overview.md` ("third-party Sidekiq gems
already add top-level keys freely, and upstream ignores unknown ones") holds
up under inspection of `job_util.rb:20`'s neighborhood, not just by
reputation.

**Decision — accepted, under these terms, for each of the three additions:**

| Slice | Key(s) | Written when |
|---|---|---|
| 05 OpenTelemetry | `traceparent`, optionally `tracestate` | only when tracing is opted in (`Telemetry.available?` **and** host opt-in) |
| 06 Status | one opt-in marker key (exact name settled in 06 against the `sidekiq-status` ecosystem suite's existing key names — must not collide) | only for a worker class with `wurk_options track: true` |
| 08 Timeout/deadline | `timeout`, `deadline`, plus `deadline_at` — the absolute epoch-float `deadline` resolves to at push, exactly as Pro's `expires_in` resolves to `expiry` (`job_util.rb`) | only when set in `wurk_options` |

**Required to hold, for every key any of the three slices add:**

- **Opt-in only.** No key appears on a job hash unless the enqueuing worker
  (or an explicit client call) asked for the feature. A host that adopts
  none of 05/06/08 gets byte-identical payloads to today — this is the
  plan's own "additive invariant," restated here as the JSON-shape half of it.
- **JSON-native values only.** Strings (`traceparent`, `tracestate`), a
  Numeric or String (`timeout`, `deadline`), nothing that needs
  `TRANSIENT_ATTRIBUTES`-style stripping. If a future addition needs to carry
  a non-JSON value through enqueue, it is a `pool`/`client_class`-shaped
  transient attribute, not a wire key, and belongs in that list instead —
  this decision does not extend to that case.
- **Never collide with an existing key.** Check `lib/wurk/keys.rb` and every
  currently-known job-hash key (`class`, `args`, `queue`, `jid`, `retry`,
  `at`, `tags`, `retry_for`, `created_at`, `expiry`, `wrapped`, `bid`, …)
  before naming a new one. 06 additionally checks the `sidekiq-status` gem's
  own key names (`test/ecosystem/`) — coexistence, not collision, per that
  slice's own file.
- **Both directions of the drop-in contract get an integration test per
  slice:** a Wurk-enqueued job carrying the new key still runs unmodified on
  stock Sidekiq (extra key is inert cargo, per the precedent above), and a
  Sidekiq-enqueued job with the key absent still runs on Wurk (feature reads
  the key as optional, never required).
- **Encryption interaction is explicit, not assumed.** Any key that is
  metadata (`traceparent`) must not be swept into `lib/wurk/encryption.rb`'s
  encrypted-args envelope; any key that could be sensitive (08's future
  extensions, 06's stored result) gets its own explicit encrypt-or-refuse
  decision in that slice's file, not inherited silently from this one.
- **`verify_json`/`validate` are untouched.** `JobUtil#validate` gains no new
  required-key check for any of these — they are optional by construction,
  and `verify_json` only walks `item['args']` (`:38-46`), never top-level
  keys, so a `traceparent` string or a `timeout` integer never touches the
  strict-args-mode reporting path. Confirmed by reading `job_util.rb:36-46`;
  no code change needed there for this decision to hold.

**Reversal trigger.** Any parity-test failure showing a real Sidekiq
`Processor` (not a gem, the core) chokes on an unrecognized top-level key —
would falsify the "unknown keys are inert cargo" premise this decision rests
on. None of the surveyed evidence (job_util.rb's shape, the two ecosystem
gems' behavior) suggests that is possible, but it is the one thing that would
require walking this back to a `pool`/`client_class`-style transient
attribute instead (computed client-side, stripped before `raw_push`, feature
becomes enqueue-time-only instead of wire-visible).

---

## Provenance

Both decisions were raised by the plan owner in `overview.md` → "Risks / open
questions": #1 as "the #394 parity call blocks slice 01… `docs/target/
sidekiq-free.md` doesn't pin the interrupted case," #2 as "job-hash key
additions… needs an explicit sign-off before 05 lands, in the shape of
`docs/plans/2026/08/06/101-faster-than-sidekiq/00-semantics-signoff.md`." This
file is that sign-off for both, following the same format: decision, cost,
required-to-hold terms, reversal trigger.

Nothing here is gated behind a flag, a tier, or an env var — pillar 2. Every
behavior described is opt-in (Decision 2) or a bugfix that applies uniformly
(Decision 1), and neither adds a paid-tier gate.
