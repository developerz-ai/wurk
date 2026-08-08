# 08 — Per-job timeout & deadline

> Part of [`overview.md`](overview.md). Depends on: none.
>
> **Additive invariant:** opt-in per worker via `wurk_options`. A worker without `timeout:`/`deadline:` gets no timer, no allocation, no behavior change.

## Why

Asynq (`Timeout`, `Deadline`), Celery (`time_limit` / `soft_time_limit`), and Dramatiq all treat this as table stakes; Sidekiq deliberately omits it. Wurk's `expires_in` (`lib/wurk/middleware/expiry.rb`) only drops a job **before** execution — nothing bounds a job that hangs on a wedged socket after it starts.

## Semantics (decide, then implement)

| Option | Meaning |
|---|---|
| `timeout: 30` | max wall-clock for **this attempt**. Exceeded → raise in the job thread → normal retry path. |
| `deadline: 5.minutes` | absolute cutoff from **enqueue**. Past it → don't start; if running, abandon. Not per-attempt — retries can't outlive it. |

Decisions to settle before code:
1. **Soft vs hard.** Celery distinguishes: soft raises a catchable exception (job can clean up), hard kills. Recommend soft-only. Hard-killing a Ruby thread mid-`perform` (`Thread#kill`) leaks connections and half-written state — exactly the class of bug the RAII pass in `docs/plans/2026/07/31/101-leak-logic-perf-fixes/` closed. If a hard kill is wanted, it belongs at the process level, not the thread.
2. **Does a timeout count as a failure?** Recommend yes — it's a real failure with a real exception, unlike the interrupted case in slice 01. But say so explicitly so `Metrics::History` treatment is deliberate.
3. **Retry interaction.** A timed-out job retries by default (`Asynq` does). A job that times out every attempt burns the retry budget and lands in the dead set — correct, but note it in docs.
4. **Deadline expiry state.** Silently dropped (like `expires_in`, which books `stat:expired` — `lib/wurk/keys.rb:48`) or booked as failed? Reuse the `expired` stat for consistency.

## Files to change

- new `lib/wurk/middleware/timeout.rb`.
- `lib/wurk/worker.rb` — accept `timeout:` / `deadline:` in `wurk_options`; validate types at declaration, not per job.
- `lib/wurk/job_util.rb` — carry the values in the payload (only when set).
- `lib/wurk.rb:258` — registration. Must sit **inside** `Batch`/`Expiry` and **outside** `Metrics::History`, so a timeout is measured and booked. Read the ordering comments before inserting.
- `lib/wurk/manager.rb` / `lib/wurk/processor.rb` — the timer's home if a per-thread timer is too costly (see step 2).

## Steps

1. Prefer `Timeout.timeout`'s successor pattern over the stdlib `Timeout` module where possible — stdlib `Timeout` spawns a thread per call and is notorious for firing inside `ensure` blocks. Measure both; a single monotonic watchdog thread per Manager scanning in-flight deadlines is likely cheaper than N timer threads and is the shape Asynq/River use.
2. Bound the cost: with no timeouts configured anywhere, the watchdog must not start at all.
3. Deadline check happens twice: at fetch (before `perform`, alongside `Expiry`) and inside the watchdog for a job already running.
4. Interaction with `IterableJob` (`lib/wurk/iterable_job.rb`): a cooperatively-interrupted job re-enqueues and resumes. A `deadline` must survive the re-enqueue (it's absolute); a `timeout` resets per attempt. Test both.
5. Interaction with `shutdown_timeout`: on TERM, in-flight jobs get the swarm's drain budget. A job `timeout` shorter than that fires first; longer, and shutdown wins. Document which.

## Tests

- Unit: job exceeding `timeout` raises, retries, books a failure.
- Unit: job past `deadline` never starts; running job past `deadline` is abandoned; `stat:expired` (or the chosen stat) increments.
- Unit: no timeout configured → watchdog never starts, zero extra threads (assert thread count).
- `IterableJob`: deadline survives interrupt+resume; timeout resets per attempt.
- Integration: real fork, real Redis, a genuinely hanging job (sleep) is cut at the bound.
- Leak check: no thread or connection leak after 1000 timed-out jobs — the RAII discipline from the previous plan applies.
- `rake bench` with no timeouts configured → within noise.

## Done when

- `wurk_options timeout: 30, deadline: 5.minutes` bounds a hanging job.
- Zero cost when unconfigured, proven by thread count + bench.
- Soft/hard, failure-booking, retry, and shutdown interactions all documented.
- No leaked threads or connections under sustained timeouts.
