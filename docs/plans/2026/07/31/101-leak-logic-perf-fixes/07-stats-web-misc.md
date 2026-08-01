# 07 — Stats correctness, poison pill, web misc

> Part of [`overview.md`](overview.md). Depends on: none.

## Files to change

- `lib/wurk/middleware/poison_pill.rb:56-92, 97-111` — clear! never called; callback registry
- `lib/wurk/metrics/history.rb:41-63` — Handled/Skip counted as failures
- `lib/wurk/stats.rb:170` — local vs UTC date
- `lib/wurk/job_set.rb:68-72` — false NX comment
- `lib/wurk/processor.rb:243-253` — WORK_STATE set outside begin
- `lib/wurk/web/config.rb:200-209` — rack_app memo ignores inner
- `app/controllers/concerns/wurk/stream_concurrency_guard.rb:30-32` — slot counter self-heal

## Steps

1. **F6 (job loss) — poison-pill counter never cleared.** `PoisonPill.clear!` (`poison_pill.rb:88`) has zero callers in `lib/`; three unlucky reclaims (OOM kills) in 72 h silently kill a healthy job to the dead set with `notify_failure: false` (death handlers never fire → batches never learn). Fix: call `clear!(jid)` on successful perform — server middleware success path or `Processor#process` post-ack; pick the spot that doesn't add a Redis call for jobs never reclaimed (guard: only clear when `job['jid']` was recovered — cheapest is clear inside `PoisonPill` middleware itself, it already knows). Reconsider `notify_failure: false` → fire death handlers on poison kill (spec-check `sidekiq-pro.md` super_fetch semantics first).
2. **F13 — `Metrics::History` counts `Limiter::Rescheduled` / `JobRetry::Skip` / `Job::Interrupted` as failures** (`history.rb:41-63`) — `Batch::ServerMiddleware#run_and_ack` (`batch/server_middleware.rb:56`) treats the same exits as neither. Fix: rescue those, record neither success nor failure, re-raise.
3. **F14 — daily stats reader uses local date, writer uses UTC** (`stats.rb:170` vs `launcher.rb:178`): non-UTC dashboards show today=0. Fix: `::Time.now.utc.to_date`. Sidekiq shares the bug → record deliberate divergence in `docs/idea/`.
4. **F15 — `JobSet#schedule` comment claims `ZADD NX`, code has none** (`job_set.rb:68-72`). Wire behavior matches Sidekiq (correct); delete/rewrite the comment only.
5. **S9 — `WORK_STATE.set` outside its begin/ensure** (`processor.rb:243-253`): async raise between set and begin pins the payload in `SharedWorkState` and inflates `busy` on every heartbeat forever. One-line: move the `set` inside `begin`.
6. **S10 — `Web::Config#rack_app` memo keyed only on middlewares, ignores `inner`** (`web/config.rb:200-209`): two callers pass different inners (`rack_app.rb:33` vs `config.rb:298`) → whichever builds first wins, other dispatches into the wrong app. Fix: key memo on `[inner, middlewares]` (one memo per inner).
7. **S11 — `PoisonPill.on_poison` append-only registry** (`poison_pill.rb:97-111`): Rails reloader re-registration accumulates duplicate closures. Fix: idempotent registration (dedupe by callable identity) or document + provide `reset!`-style deregistration for the reloader path.
8. **S13 — `StreamConcurrencyGuard` counter can't self-heal** (`stream_concurrency_guard.rb:30-32`): hard-reaped Puma thread skips `ensure` → permanent 503 after 10 leaks. Fix: registry of `{token → monotonic timestamp}`; acquire evicts entries older than `STREAM_MAX_DURATION` (120 s, `sse_streaming.rb`) before counting.

## Tests

- Unit: reclaimed job that then succeeds → `super_fetch:recovered:<jid>` deleted; three-reclaims-then-success does not dead-set.
- Unit: rate-limited job rescheduled N times → zero `|f` entries in `j|` hashes.
- Unit: `Stats::History` with TZ=Pacific/Auckland at a UTC/local date boundary → today bucket matches writer key.
- Unit: `rack_app` called with two inners → each dispatches to its own app.
- Unit: stream guard with leaked (never-released) slots older than max duration → new acquires succeed.
- Commands: `bin/rake test`, `bin/rake test:parity`.

## Done when

- Poison-pill kill requires 3 reclaims *without an intervening success*; death handlers decision recorded.
- Failure charts unaffected by limiter reschedules; TZ test green.
- Both web-layer state bugs fixed; coverage holds.
