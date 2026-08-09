# OpenTelemetry tracing

A producer span on enqueue whose W3C trace context rides the job hash across
the Redis hop, and a linked consumer span when a worker picks the job up —
one trace that follows a job from `push` to `perform`, in-process or across a
forked swarm.

> **Wurk-only extra — not a Sidekiq parity feature.** Stock Sidekiq ships no
> first-party tracing at all; getting a trace today means bolting on a
> third-party gem (e.g. `opentelemetry-instrumentation-sidekiq`) that instruments
> `perform` in isolation. Migrating a Wurk app back to stock Sidekiq means
> losing the automatic producer→consumer link across the Redis hop — you keep
> per-job spans (via that same third-party gem) but lose the free enqueue-to-execute
> trace this page describes.

## Contents

- [Off unless enabled](#off-unless-enabled)
- [Enabling it](#enabling-it)
- [What gets instrumented](#what-gets-instrumented)
- [The one JSON addition](#the-one-json-addition)
- [Retry semantics](#retry-semantics)
- [Long-delay and scheduled jobs](#long-delay-and-scheduled-jobs)
- [Error and interruption taxonomy](#error-and-interruption-taxonomy)
- [Encryption interaction](#encryption-interaction)
- [Zero-cost proof](#zero-cost-proof)
- [See also](#see-also)

## Off unless enabled

Two things have to be true before a single span is emitted or a single byte
is added to the job payload:

1. The host called `config.telemetry = true`.
2. The `opentelemetry-api` gem is loaded in that process.

`opentelemetry-api` is **not** a `wurk.gemspec` dependency. A host that never
traces never carries the gem; a host that does already has it, since every
OTel SDK, exporter, and instrumentation gem depends on the API package.
`Wurk::Telemetry.available?` checks for `::OpenTelemetry` responding to
`propagation` and `tracer_provider` rather than trusting the bare constant —
some other library can own `OpenTelemetry` without it being the real API, and
this check turns that mismatch into "tracing stays off" rather than a
`NoMethodError` on the first job of a deploy.

With tracing off — no opt-in, or opt-in with the gem missing — the payload
and hot path are byte-identical to a build with `lib/wurk/telemetry.rb` never
required. `require "wurk"` does not load `wurk/telemetry`; only
`Wurk::Configuration#telemetry=` does, so an app that never opts in never
even resolves the `opentelemetry-api` require.

## Enabling it

```ruby
Wurk.configure_server do |config|
  config.telemetry = true
end
```

Add `opentelemetry-api` (and an SDK/exporter of your choice) to the host
app's Gemfile:

```ruby
gem 'opentelemetry-api'
gem 'opentelemetry-sdk'
gem 'opentelemetry-exporter-otlp' # or whatever exporter your backend needs
```

If `config.telemetry = true` is set but `opentelemetry-api` isn't installed,
Wurk logs a warning (`'config.telemetry = true but opentelemetry-api is not
installed; tracing stays off'`) and leaves tracing off rather than raising.
Turning tracing back off (`config.telemetry = false`) unregisters both
middlewares without re-loading anything.

There is no `Sidekiq::Telemetry` alias — upstream Sidekiq has no such
constant, so aliasing one would invent a Sidekiq surface rather than mirror
an existing one.

## What gets instrumented

A client/server middleware pair, both under `lib/wurk/telemetry/`, installed
by `Wurk::Telemetry.install!` only once both halves of the gate above hold:

| Side | Span | When |
|---|---|---|
| `Wurk::Telemetry::ClientMiddleware` | `<queue> publish` (producer) | Around every `push`, and around each item of a `push_bulk` — the client middleware chain runs per item on the bulk path, so each job gets its own span and its own injected context. |
| `Wurk::Telemetry::ServerMiddleware` | `<klass> process` (consumer) | Around the rest of the server chain and `perform`, so its duration is the job's real wall clock, not `perform`'s alone. |

Both spans carry the same attribute set, using OTel's **messaging** semantic
conventions:

- `messaging.system` — always `wurk`
- `messaging.destination.name` — the queue name
- `messaging.message.id` — the job's `jid`
- `messaging.wurk.job_class` — `job['wrapped'] || job['class']`, i.e. the
  real class behind an ActiveJob wrapper, not the adapter class

`messaging.wurk.job_class` sits in the `messaging.<system>.*` extension slot
the conventions reserve for vendor-specific fields — the same slot
`opentelemetry-instrumentation-sidekiq` uses for its own job-class attribute.

The client middleware runs last (tail position) in the client chain: a
middleware that halts the push — a uniqueness gem dropping a duplicate — runs
outside it, so no publish span opens for a job that was never actually
published, and nothing downstream can strip the injected key back off. The
server middleware installs one position inside `Wurk::Middleware::InterruptHandler`,
as far out as it can sit while staying inside that handler — see
[Error and interruption taxonomy](#error-and-interruption-taxonomy) for why.

## The one JSON addition

`traceparent` — and `tracestate`, only when the trace actually carries vendor
state — become extra top-level string keys on the job hash. This is the only
payload change tracing makes, and the keys appear **only** when tracing is
enabled; an untraced push and a traced push are byte-identical except for
these keys (`test/unit/telemetry_client_middleware_test.rb`,
`test_opting_in_adds_the_trace_context_and_nothing_else`).

This is a documented, sanctioned parity divergence — recorded in
[`docs/idea/parity-divergences.md`](idea/parity-divergences.md) — not an
accident:

- **Drop-in both directions.** A job traced and enqueued by Wurk runs
  unmodified on stock Sidekiq: `Sidekiq::Processor#dispatch` and
  `Sidekiq::JobLogger#prepare` read the job hash exclusively by known key
  name off a plain `JSON.parse`, so `traceparent` is inert cargo to a real
  stock-Sidekiq dispatch, not a protocol violation
  (`test/unit/telemetry_client_middleware_test.rb`,
  `test_a_traced_job_dispatches_unmodified_through_stock_sidekiqs_processor`).
  A stock-Sidekiq job with no `traceparent` at all still runs cleanly under a
  Wurk swarm with tracing on — it just starts as a root span with nothing to
  link to (`test/integration/telemetry_fork_test.rb`,
  `test_a_stock_sidekiq_shaped_job_with_no_traceparent_is_consumed_here`).
- **Precedent.** sidekiq-cron, sidekiq-unique-jobs, and sidekiq-status all
  add their own top-level keys to the job hash; nothing in Sidekiq's dispatch
  path enumerates or validates the full key set.

## Retry semantics

A retried job carries the **original** `traceparent`, not a fresh one.
`JobRetry#schedule_retry` re-`ZADD`s the same job hash it already has, so the
client chain — and with it the injection step — never runs again for a
retry. That means one trace per logical job across every attempt: attempt 1
usually lands inside the [parent window](#long-delay-and-scheduled-jobs) and
shows up as a child span, and later attempts, pushed further out by
exponential backoff, land outside the window and become root spans carrying
a **link** back to the original producer span instead. Neither case is ever
an unrelated, untraceable root — every attempt is reachable from the enqueue
that caused it.

## Long-delay and scheduled jobs

A job enqueued now and executed six hours later (a `perform_in`, a cron
tick, a backed-off retry) has a long-dead producer span by the time it runs.
Hanging a parent-child edge off it would stretch the trace across hours and,
depending on the backend's sampling/retention window, split or drop it
entirely. Past a threshold, the consumer span becomes a **link** to the
producer instead of a **parent**:

- **Threshold:** `Wurk::Telemetry::ServerMiddleware::PARENT_WINDOW_SECONDS = 60`.
  Under 60 seconds of age, the consumer span is a child of the producer span.
  At or past it, the consumer span is a root span carrying a `Link` to the
  producer's span context.
- **Age is measured from `created_at`** (stamped once, at push), not
  `enqueued_at` (which the scheduler re-stamps when it moves a job onto the
  queue — using it would make every scheduled job look artificially fresh).
- `created_at` is read shape-agnostically: Sidekiq 8.x+ stamps epoch millis,
  but older jobs sitting in retry/scheduled/dead sets from a pre-upgrade
  Sidekiq can still carry epoch *seconds*. Anything under 10<sup>10</sup> is
  treated as seconds; at or above it, millis.
- A missing/invalid producer context (no `traceparent`, or an already-invalid
  one) also resolves to a link-less root — never crashes, never guesses.

The asymmetry is deliberate: a link where a parent belonged costs one extra
hop when reading the trace in a UI, while a parent where a link belonged can
lose the trace entirely. Unknown age always resolves to a link.

## Error and interruption taxonomy

The consumer span's error status is deliberately narrower than "any
exception raised inside `perform`":

- **Not recorded as an error:** `Wurk::JobRetry::Handled` (which is where
  `JobRetry::Skip` and, under it, `Limiter::Rescheduled` live) and
  `Wurk::Job::Interrupted`. These are jobs that were put back and will run
  again — a rate limit rescheduling a job, or a cooperative stop during a
  rolling restart — not jobs that went wrong. Marking the span an error here
  would paint a rate-limited or gracefully-paused deploy as an outage. The
  span still finishes, just without `record_exception` or an error status.
- **Recorded as an error:** everything else, including `Wurk::Shutdown` — a
  job killed by a hard shutdown genuinely did not complete, and that is
  exactly the signal an operator tuning `shutdown_timeout` wants to see in
  their tracing backend.

This is why the server middleware installs *inside*
`Wurk::Middleware::InterruptHandler` rather than outside it: `InterruptHandler`'s
own rescue is what turns a cooperative stop into a re-push plus
`JobRetry::Skip` in the first place. From outside that handler, the span
would also wrap the Redis `RPUSH` that puts the job back — work that isn't
part of running the job at all.

## Encryption interaction

`traceparent` is metadata, not an argument. [Encrypted args](encryption.md)
only ever touch `args.last` — the encrypted-args envelope neither encrypts
the trace context nor is perturbed by its presence. Encrypted args and
tracing compose cleanly with no special-casing required on either side
(`test/unit/encryption_test.rb`, the "telemetry interaction" section).

## Zero-cost proof

`rake bench` with tracing off is proven to sit within noise of `main` — the
additive invariant this feature is built on (see the [design
doc](plans/2026/08/07/101-beyond-sidekiq/05-opentelemetry.md)'s "Done when").
This is a regression-gate claim about Wurk against its own past self, not a
comparison against stock Sidekiq — see `docs/benchmarks.md` for where Wurk
currently stands against Sidekiq on the workloads that matter.

## See also

- [`docs/plans/2026/08/07/101-beyond-sidekiq/05-opentelemetry.md`](plans/2026/08/07/101-beyond-sidekiq/05-opentelemetry.md) — the design doc this feature was built from.
- [`docs/idea/parity-divergences.md`](idea/parity-divergences.md) — the `traceparent`/`tracestate` JSON-key divergence entry, with test citations.
- [`docs/encryption.md`](encryption.md) — how encrypted args and trace context coexist.
