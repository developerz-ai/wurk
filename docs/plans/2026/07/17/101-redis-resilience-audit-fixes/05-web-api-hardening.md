# 05 — Web/API hardening

> Part of [`overview.md`](overview.md). Depends on: 01 (pool config plumbing).

## Files to change

- `app/controllers/wurk/api_controller.rb:25-32` — CSRF skipped with no same-origin guard on all mutating endpoints.
- `app/controllers/wurk/extensions_controller.rb:18-19,53` — reference `verify_same_origin!` implementation.
- `lib/wurk.rb:129-137` + `lib/wurk/capsule.rb:95-99` — web layer rides the worker-sized pool.
- `app/controllers/wurk/api_controller.rb:20,287-438` — SSE holds a Puma thread 600s/client, no stream cap.
- `lib/wurk/web/search.rb:67-90` — unbounded full-LIST scans per keystroke.
- `app/controllers/wurk/api_controller.rb:416`, `app/controllers/wurk/profiles_controller.rb:41` — raw key access in controllers (layer reach-through).
- `lib/wurk/engine.rb:48-57` — asset mount bypasses authorization middleware.
- `lib/wurk/history.rb:64-91`, `lib/wurk/metrics/rollup.rb:54-78`, `lib/wurk/metrics/queue_rollup.rb` — triplicated timer-loop scaffolding.

## Steps

1. **CSRF.** Add `before_action :verify_same_origin!` to `ApiController` for all non-GET actions — same `Sec-Fetch-Site` check as `ExtensionsController#verify_same_origin!` (`extensions_controller.rb:53`); extract to a shared concern. Standalone Rack path already enforces (`lib/wurk/web/rack_app.rb:38-46`) — engine path must match. One-line-class fix, highest security priority.
2. **Web pool.** Give the web/API/SSE layer its own pool: `Configuration#web_redis_pool` (lazy, size configurable, default 5, `pool_timeout` 1.0) and route `Wurk.redis` calls made from web context through it — cleanest: web entry points (ApiController, rack_app, SSE tick, Search) set `Thread.current[:wurk_capsule]`-equivalent to a web capsule/pool handle; `Wurk.redis` already reads a thread-local (`lib/wurk.rb:136`). Dashboard load can no longer exhaust the worker pool (and vice versa).
3. **SSE limits.** Cap concurrent streams (global counter, default 10; 503 + `retry:` header beyond), and lower `STREAM_MAX_DURATION` 600s → 120s (client auto-reconnects transparently; frontend already falls back to polling). Keep per-tick connection release (already correct).
4. **Search bounds.** `Search#search_queues` (`web/search.rb:67-90`): cap total scanned elements per queue (e.g. 5_000) and per-request scan budget; return `truncated: true` in the payload so the UI can say "showing partial results". Never full-walk a multi-million LIST from a keystroke.
5. **Layer reach-through.** Move raw `HGETALL lmtr:*` (`api_controller.rb:416`) and `HGET` profile data (`profiles_controller.rb:41`) behind the existing inspector objects (`Wurk::Limiter` API / profile model) — controllers stop hardcoding key schema.
6. **Asset auth note.** `AssetMount` on the host stack (`engine.rb:48-57`) serves the bundle unauthenticated. Assets are non-sensitive by design — document that decision in the engine comment + README security section rather than moving the mount (perf: static serving without engine middleware is deliberate). If maintainer wants gating: move behind the engine stack instead.
7. **Timer-loop dedup.** Extract the copy-pasted mutex/CV `start`/`terminate`/`wait` + leader-gate boilerplate from `History`, `Metrics::Rollup`, `Metrics::QueueRollup` into one `Wurk::TimerLoop` (three real consumers exist — abstraction is warranted, not speculative).
8. **Observability.** Wrap API endpoints' Redis access so an outage returns a structured 503 JSON (`{error: "redis_unavailable"}`) instead of a raw 500; frontend can surface it (06). Reuse the 01 `:redis_error` hook for visibility.

## Steps NOT taken (documented decisions)

- `ApiController` god-object split (40+ actions): worthwhile but big-bang refactor risk; do after this plan lands, per-resource like `lib/wurk/web/` — file an issue, don't block.
- Dashboard unauthenticated-by-default: matches Sidekiq; keep, but README must state it loudly.
- Read-only probe hardcoded to `POST /api/retries` (`api_controller.rb:304-317`): acknowledged latent inconsistency, middleware still enforces per-path — leave.

## Tests

- Request specs (engine layer, `test/` engine suite boots `test/dummy/`): non-GET without `Sec-Fetch-Site: same-origin` → 403; with → 2xx. All mutating routes covered by a route-table-driven test.
- Web pool isolation: saturate web pool in test → worker pool checkout still succeeds.
- SSE: 11th concurrent stream → 503; stream closes at cap duration.
- Search: seeded 10k-job queue with zero matches → bounded round-trips (assert via command counter middleware), `truncated` flag set.
- Commands: `bin/rake test`.

## Done when

- Cross-site POST to any mutating endpoint is rejected on the engine path.
- Dashboard load cannot consume worker-pool connections (pools disjoint).
- Search on a huge queue returns bounded-time partial results.
- Redis outage yields structured 503s, not raw 500s.
