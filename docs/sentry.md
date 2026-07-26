# Sentry

Wurk ships a first-class, opt-in [Sentry](https://sentry.io) integration:
`Wurk::Sentry`. It reports job failures and worker-process errors, scopes every
event to the job that produced it, and reports each failing job **once** rather
than once per retry.

It is opt-in and inert by default. `sentry-ruby` is **not** a runtime dependency
of the gem — every call site is guarded, so loading this file in an app without
sentry-ruby (or before `Sentry.init` has run) does nothing.

---

## Why not `sentry-sidekiq`?

Because it cannot be installed alongside Wurk. `sentry-sidekiq`'s gemspec
declares:

```ruby
spec.add_dependency "sidekiq", ">= 3.0"
```

Wurk is a drop-in *replacement*, not a plugin: you remove the `sidekiq` gem and
the `Sidekiq::*` constants come from Wurk instead. Adding `sentry-sidekiq` pulls
real Sidekiq back into the bundle, and `require "sidekiq"` then resolves to
whichever of the two Bundler put on the load path first. The result is a hybrid
process — Wurk's swarm, Sidekiq's constants, or some interleaving of both — that
fails in ways no stack trace explains.

This is the same problem every ecosystem gem has, and Wurk's general answer is
the [`ecosystem/sidekiq-shim/`](../ecosystem/sidekiq-shim/README.md) git source,
which satisfies a `sidekiq` dependency *with* Wurk:

```ruby
# Gemfile — the escape hatch for gems you must keep
gem "wurk"
gem "sidekiq", github: "developerz-ai/wurk", glob: "ecosystem/sidekiq-shim/*.gemspec"
gem "sentry-sidekiq"
```

That works, but it buys you an integration written against Sidekiq's internals
to solve a problem Wurk has natively. Prefer `Wurk::Sentry` — and note that
`sentry-sidekiq`'s error reporting would be **wrong** on Wurk anyway, for the
reason in [What gets reported](#what-gets-reported) below.

---

## Setup

```ruby
# config/initializers/sentry.rb — unchanged; sentry-ruby only
Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.traces_sample_rate = 0.1
end
```

```ruby
# config/initializers/wurk.rb
require "wurk/sentry"

Wurk.configure_server do |config|
  Wurk::Sentry.install!(config)
end
```

`Gemfile`: you need `sentry-ruby` (and `sentry-rails` if you want the rest of
the Rails integration). You do **not** need — and must not add —
`sentry-sidekiq`.

```ruby
gem "wurk"
gem "sentry-ruby"
gem "sentry-rails"   # optional
```

`install!` is idempotent, so calling it twice (or from two initializers) never
doubles a report.

---

## What gets reported

Two things are registered, and both are necessary.

**1. Server middleware** (`Wurk::Sentry::Middleware`) — job failures.

A job failure never reaches `config.error_handlers` in Wurk. `JobRetry#local`
rescues the exception, books the retry, and raises `Wurk::JobRetry::Handled`,
which `Processor#process` swallows to ack the unit of work. An error handler
alone therefore sees **no job exceptions at all** — this is the trap any
Sidekiq-era error-reporting setup falls into on Wurk. The middleware runs
*inside* `JobRetry#local` (see `Processor#dispatch`), which is the only place
the raw exception is still in flight, so that is where the capture lives. The
exception is always re-raised: Wurk's retry pipeline, not Sentry, owns the
failure.

**2. Error handler** (`Wurk::Sentry::ErrorHandler`) — everything else.

`config.error_handlers` still fires for the failures that are *not* a job:

| `context:` | Raised by |
|---|---|
| `"Error fetching job"` | the fetch loop (`Processor#fetch`) |
| `"!shutdown"` | an exception escaping the processor run loop |
| `"Invalid JSON"` | an unparseable payload, on its way to the dead set |
| `"Error calling retries_exhausted"` / `"Failure scheduling retry via \`sidekiq_retry_in\`"` / `"Error calling death handler"` | a raising host callback inside the retry machinery |

The handler is appended, so Wurk's default logging handler keeps running — every
reported error is still in your logs.

---

## Only the terminal failure is reported

A job with the default `retry: true` gets 25 attempts spread over roughly 21
days. Reporting each one would put 25 events on a single issue and page you 25
times for one broken job. `Wurk::Sentry` reports **only the attempt that ends
the job** — the one after which the payload goes to the dead set (or is
discarded).

`Wurk::Sentry::RetryPolicy` predicts that ahead of `JobRetry`, because the
middleware's rescue runs *before* the retry layer touches the payload:

- `JobRetry#bump_retry_count` sets `retry_count = 0` on the first failure and
  `retry_count += 1` on every one after, so the post-bump count is
  `retry_count.nil? ? 0 : retry_count + 1`.
- `JobRetry#exhausted?` kills the job once that count reaches `max_attempts`.

So the last attempt is the one that arrives at the middleware with
`retry_count == max_attempts - 1`:

| `sidekiq_options` | `max_attempts` | reported when |
|---|---|---|
| `retry: true` (default) | `config[:max_retries]`, else 25 | `retry_count == 24` |
| `retry: 5` | 5 | `retry_count == 4` |
| `retry: 0` | 0 | first failure (`retry_count` absent) |
| `retry: false` | — | first failure |
| `retry_for: 1.hour` | wall clock | first failure after `failed_at + retry_for` |

Two cases the payload cannot predict, and where the report is therefore one
attempt late or absent: a `sidekiq_retry_in` block returning `:discard` or
`:kill`. Those are host decisions made after the middleware has already
re-raised.

`Wurk::Shutdown` is never reported. A job interrupted by a deploy is not
acked — it stays in the private list and runs again on the next boot. Exceptions
*caused by* a `Wurk::Shutdown` (user code that rescued it and raised something
else) are skipped too, matching `JobRetry`'s own rule.

---

## What each event carries

| | |
|---|---|
| Transaction | `Wurk/<JobClass>` |
| Tags | `queue`, `jid` |
| Context (`wurk`) | `class`, `jid`, `queue`, `retry_count`, `created_at`, `enqueued_at` |

Sentry groups issues by transaction name, and `sentry-sidekiq` names its
transactions `Sidekiq/<JobClass>`. `Wurk/<JobClass>` mirrors that shape on
purpose: a migrating app's issue list stays legible, the same job reads the same
way before and after the swap, and history stays searchable instead of
fragmenting into unnamed transactions.

**Job arguments are never sent.** Not in the job context, and not in the error
handler's `extra:` — a job hash arriving there has its `args` stripped, and the
raw `jobstr` of an unparseable payload is dropped wholesale. Payloads routinely
carry PII, tokens, and `encrypt: true` ciphertext; Sentry is not where any of
that belongs. The context is an enumerated allow-list, so a payload key a future
Wurk release starts stamping cannot leak into it by accident.

The integration sets a scope; it does not start a Sentry **transaction**, so
jobs do not show up under Performance. Use
[`docs/metrics.md`](metrics.md) for job timing.

---

## Noise filtering

By default the error handler drops exceptions whose ancestry includes
`RedisClient::Error` or `ConnectionPool::TimeoutError` — the same list Wurk's
default handler logs at WARN instead of INFO
(`Wurk::Configuration::REDIS_ERROR_CLASSES`), because both are self-healing:
the pool already retried before re-raising, and the fetch loop retries again a
second later.

This matters more than it sounds. The fetch loop runs a tight
`rescue → handle_exception → sleep(1)` cycle across every thread of every forked
worker, so a backend that blips returns a report *per thread per second*. On one
production deployment against a Dragonfly backend, a single Sentry issue
accumulated ~136,000 events from fetch-loop blips while the job pipeline was
completely healthy — enough to blow through an event quota and bury the real
issues.

These stay in the logs. They just stop paging anyone.

Turn it off, or change the list:

```ruby
Wurk.configure_server do |config|
  # report everything, including transport blips
  Wurk::Sentry.install!(config, filter_transport_errors: false)

  # or extend the default list
  Wurk::Sentry.install!(
    config,
    filtered_error_classes: Wurk::Sentry::ErrorHandler::DEFAULT_FILTERED_ERROR_CLASSES + [Net::OpenTimeout]
  )
end
```

Note the filter applies to the **error handler** only — a job that raises
`RedisClient::CannotConnectError` is still reported when it exhausts its
retries. Filtering is about the infrastructure loop, not about your jobs.

---

## API

```ruby
Wurk::Sentry.install!(config = Wurk.configuration,
                      filter_transport_errors: true,
                      filtered_error_classes: nil) # => config
```

| Argument | Default | Meaning |
|---|---|---|
| `config` | `Wurk.configuration` | the `Wurk.configure_server` block argument |
| `filter_transport_errors:` | `true` | drop self-healing transport errors in the error handler |
| `filtered_error_classes:` | `nil` | replaces `ErrorHandler::DEFAULT_FILTERED_ERROR_CLASSES` |

```ruby
Wurk::Sentry.enabled?   # => sentry-ruby loaded AND Sentry.init has run
```

Nothing is auto-installed. `require "wurk/sentry"` on its own registers no
middleware and no handler — the integration touches your error stream only after
an explicit `install!`, which is the same opt-in shape as
`Wurk::Metrics::Statsd`.

---

## Migrating from `sentry-sidekiq`

1. **Remove `sentry-sidekiq` from the `Gemfile`.** Keep `sentry-ruby`. Nothing
   in `config/initializers/sentry.rb` changes.
2. **Add the two lines** from [Setup](#setup) to your Wurk initializer.
3. **Delete any `Sentry::Sidekiq::*` references.** Wurk defines no
   `Sentry::Sidekiq` constants — the namespace here is `Wurk::Sentry`.

| `sentry-sidekiq` | `Wurk::Sentry` |
|---|---|
| auto-installed on `require` | explicit `Wurk::Sentry.install!(config)` |
| `Sentry::Sidekiq::SentryContextServerMiddleware` | `Wurk::Sentry::Middleware` |
| `Sentry::Sidekiq::ErrorHandler` | `Wurk::Sentry::ErrorHandler` |
| transaction `Sidekiq/MyJob` | transaction `Wurk/MyJob` |
| `config.sidekiq.report_after_job_retries` (default `false` — reports every attempt) | always terminal-only; not configurable |
| starts a Sentry transaction (Performance) | scope only; see [`docs/metrics.md`](metrics.md) |
| job `args` included in the event context | never included |

**Expect your issue volume to drop.** `report_after_job_retries` defaults to
`false` in `sentry-sidekiq`, so a stock setup reports all 25 attempts of a
failing job; Wurk reports one. Combined with the transport-noise filter, a
migrated app usually sees a large fall in event count with no loss of signal.

Issue history stays grouped per job class — only the transaction prefix changes
(`Sidekiq/` → `Wurk/`), so searching `transaction:*MyJob` spans the cutover.

---

## Troubleshooting

**No events at all.** Check `Wurk::Sentry.enabled?` inside a job: it is `false`
until `Sentry.init` has run. Initializer order matters — `Sentry.init` must
happen before the first job runs, not before `install!` (the guard is evaluated
per call, not at install time).

**Events, but no `wurk` context.** Something is capturing the exception before
the middleware — usually an `ActiveJob` `rescue_from`, or `sentry-rails`
catching it higher up. The Wurk scope only applies to exceptions that reach the
middleware's rescue.

**Still seeing one event per retry.** You probably also have `sentry-sidekiq`
installed through the shim, or a hand-rolled `rescue → Sentry.capture_exception`
in a job or in another server middleware. Remove one of them.

**A failing job never reports.** Its retries are not exhausted yet — that is the
design. Check `Wurk::RetrySet` / the dashboard for the pending retry, or set
`sidekiq_options retry: 3` on jobs whose failures need to be loud sooner.
