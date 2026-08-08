# 05 — OpenTelemetry

> Part of [`overview.md`](overview.md). Depends on: none.
>
> **Additive invariant:** not required, not loaded, not registered unless the host opts in. With OTel absent, zero new objects, zero new Redis commands, zero new JSON keys — byte-identical behavior to today.

## Why

BullMQ 5.x, Temporal, and JobRunr ship first-party tracing; Sidekiq needs a third-party gem. A producer span that links to the consumer span across the Redis hop is the single most-requested observability feature in every survey ([`00-census.md`](00-census.md)).

## Shape

A client/server middleware **pair**, in a new `lib/wurk/telemetry/`:

| Side | Does |
|---|---|
| Client middleware | Inject W3C `traceparent` (+ `tracestate` if present) into the job hash under a single key. Start/end a `<queue> publish` producer span. |
| Server middleware | Extract the context, open a `<klass> process` consumer span **linked** to the producer, set standard messaging attributes, record the exception on failure. |

Attribute names follow the OTel **messaging** semantic conventions (`messaging.system=wurk`, `messaging.destination.name=<queue>`, `messaging.message.id=<jid>`) — do not invent a private vocabulary.

## The one JSON addition

`traceparent` (and optionally `tracestate`) become extra top-level keys in the job hash. This is the plan's only unavoidable payload change.

- Precedent: sidekiq-cron, sidekiq-unique-jobs, sidekiq-status all add top-level keys; Sidekiq's own `Processor` ignores unknown keys.
- Contract: a Wurk-enqueued traced job **must still run unmodified on stock Sidekiq**, and a Sidekiq-enqueued job with no `traceparent` must run here. Both directions get an integration test.
- Needs the sign-off recorded in `docs/idea/parity-divergences.md` before merge (overview "Risks").
- Keys appear **only** when tracing is enabled.

## Files to change

- new `lib/wurk/telemetry.rb`, `lib/wurk/telemetry/client_middleware.rb`, `lib/wurk/telemetry/server_middleware.rb`.
- `lib/wurk.rb:258-306` — registration, guarded: only when the host calls the opt-in. Read the ordering comments at `:258`, `:273`, `:285` before choosing a position. The server span should wrap as much of the chain as possible → register **early** (outer), but stay inside `InterruptHandler` so an interruption isn't recorded as a span error (same trap as slice 01).
- `lib/wurk/configuration.rb` — the opt-in accessor.
- `wurk.gemspec` — **no** hard dependency. `opentelemetry-api` stays an optional runtime require; the middlewares no-op if the constant is missing.

## Steps

1. Optional-dependency guard: `require`-rescue at load, and a `Telemetry.available?` predicate. Nothing registers unless both "gem present" and "host opted in" hold.
2. Client middleware: inject on `push` and on every `push_bulk` item. Bulk is the Lua path (`client.rb:84`, `:300`) — verify the injected key survives it and doesn't defeat the single-`verify_json` optimization from `docs/plans/2026/08/06/101-faster-than-sidekiq/04-enqueue-client.md`.
3. Server middleware: extract, open a linked span, set attributes, `record_exception` + error status on a real failure. Treat `Wurk::Job::Interrupted`, `JobRetry::Skip`, and `Limiter::Rescheduled` as **not** errors — see `lib/wurk/batch/server_middleware.rb:56` for the canonical rescue list.
4. Retries: a retried job carries the original `traceparent`. Decide — link to the original trace (recommended, one trace per logical job) vs. a fresh root per attempt. Document the choice.
5. Scheduled/cron jobs: a job enqueued now and run in 6 hours has a long-dead producer span. Use a span **link**, not a parent-child edge, past some threshold. Document.
6. Encryption interaction (`lib/wurk/encryption.rb`): `traceparent` is metadata, not an argument — it must **not** be encrypted, and must not break the encrypted-args round-trip. Test explicitly.

## Tests

- Unit: injection present when enabled, absent when disabled (byte-compare the payload against the non-traced one).
- Unit: extraction + link; interrupted/skipped/rescheduled jobs produce a non-error span.
- Integration (real Redis, real fork): traced enqueue → traced execute, parent-child/link intact across the process boundary.
- **Drop-in:** a traced job consumed by a stock Sidekiq worker; a stock-Sidekiq job (no `traceparent`) consumed here.
- Encryption: encrypted args + tracing enabled, both survive.
- `rake bench` with tracing **off** — must be within noise of main. Report the numbers.
- Full `bin/rake test`, `test:parity`, `test:ecosystem`. Coverage ≥90/90.

## Done when

- Enqueue and execute spans link across the Redis hop, in-process and across forks.
- OTel gem absent or opt-in off → payload and hot path byte-identical to today, proven by test and by `rake bench`.
- Drop-in both directions proven.
- Retry and long-delay semantics documented; JSON addition recorded in `docs/idea/parity-divergences.md`.
