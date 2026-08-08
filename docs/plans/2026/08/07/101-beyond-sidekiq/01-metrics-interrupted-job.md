# 01 — Interrupted IterableJob booked as a failure (#394)

> Part of [`overview.md`](overview.md). Depends on: none. Independent of every other slice — land it first.

Known issue: [#394](https://github.com/developerz-ai/wurk/issues/394). Carried from `docs/plans/2026/07/31/101-leak-logic-perf-fixes/status.yml` as **F13**, deliberately left for a parity determination.

## Symptom

One cooperatively-interrupted `IterableJob` books one spurious `<klass>|f`, then books `<klass>|p` when it resumes and completes. Dashboard failure rate inflates for any app that interrupts iterable jobs across restarts.

## Why

`Metrics::History#call` (`lib/wurk/metrics/history.rb:65-86`) treats *any* exception escaping `yield` as `success = false`. `InterruptHandler` self-prepends (`lib/wurk/middleware/interrupt_handler.rb:46`), so it sits **outside** `Metrics::History` — `Wurk::Job::Interrupted` propagates up *through* the metrics middleware before `InterruptHandler` (`:31`) catches it, re-pushes, and converts to `JobRetry::Skip`.

`Wurk::Batch::ServerMiddleware` already models the right treatment (`lib/wurk/batch/server_middleware.rb:56`): a handled/skip exit or a cooperative interruption is **neither** success nor failure.

Not affected: `Limiter::Rescheduled` — the limiter middleware is outside `Metrics::History` (`lib/wurk.rb:285-291`) and raises without ever yielding to it, so a rescheduled job isn't counted at all today. Only in play if a host app reorders the chain. Real failures are also correct: `JobRetry::Handled` comes from `retrier.local`/`global`, which wrap the chain from outside, so `Metrics::History` sees the raw exception.

## Blocking decision (settle before writing code)

Record the outcome in `docs/idea/parity-divergences.md` if it diverges from upstream.

| Question | Options |
|---|---|
| Does an interrupted run book `p`/`f` at all? | neither (suggested) · `p` · `f` (today) |
| Does it book `<klass>|ms`? | no (consistent with batch middleware's all-or-nothing) · yes (it consumed real wall-clock; omitting under-reports "time spent in FooJob") |

Oracle: upstream Sidekiq `Metrics::ExecutionTracker`. `docs/target/sidekiq-free.md` does **not** pin the interrupted case — check the real implementation, not the spec doc. If upstream also counts it as a failure, fixing it is an intentional divergence and must be documented as one.

## Files to change

- `lib/wurk/metrics/history.rb:65-86` — `#call`: rescue `Wurk::Job::Interrupted` and re-raise without recording (per the decision above).
- `lib/wurk/metrics/statsd.rb:145` — identical shape, same question. Sidekiq **Pro §9** parity. Fix in the same pass or the two emitters disagree.
- `docs/idea/parity-divergences.md` — record the divergence if any.
- `CHANGELOG.md` — `[Unreleased]`, behavior change.

## Steps

1. Settle the two questions above. Write the answer + reasoning at the top of this file before touching code (same pattern as `docs/plans/2026/08/06/101-faster-than-sidekiq/00-semantics-signoff.md`).
2. `history.rb#call` — add the rescue. Suggested shape from the issue:
   ```ruby
   rescue Wurk::Job::Interrupted
     raise   # neither success nor failure; recorded when the job resumes and completes
   ```
   Mind the existing `ensure`-based recording: the fix must prevent the record, not just re-raise past it.
3. Mirror in `metrics/statsd.rb:145`.
4. Confirm `Limiter::Rescheduled` behavior is unchanged (it never reaches these middlewares) and add a regression test that pins that ordering assumption — it is the thing a future chain reorder would silently break.

## Tests

- Unit: interrupted job through the real chain → no `|f` bucket written, `|p` written once after resume+completion.
- Unit: genuinely failed job still books `|f` (guard against over-broad rescue).
- Unit: `Limiter::Rescheduled` still books nothing; assert the chain order that makes it so.
- Statsd equivalents for all three.
- `bin/rake test TEST=test/unit/metrics_history_test.rb`, then full `bin/rake test` + `test:parity`. Coverage ≥90/90.

## Done when

- One interruption produces exactly one `p` and zero `f` for the class.
- `Metrics::History` and `Metrics::Statsd` agree.
- Decision recorded; divergence (if any) in `docs/idea/parity-divergences.md` and `CHANGELOG.md`.
- #394 closed with the parity determination written in the issue.
