# 21 — Counters + read-side round-trip collapsing

> Part of [`overview.md`](overview.md). Added 2026-11-10 on owner request ("counter caching, tricks, optimizations"). Depends on: wave 1 merged; the round-trip-counting engine helper (07 A14). Wave 4, agent B's file set (`app/controllers/wurk/`, `lib/wurk/api/`). Source: read-only survey at `c49c69d`; nothing measured yet.

## Already done (don't redo)
- Per-job counters are batched: `stat:processed|failed|expired` + daily keys accumulate in memory (`lib/wurk/processor.rb` `PROCESSED`/`FAILURE` counters) and flush once per heartbeat in one pipeline (`lib/wurk/launcher.rb` flush) — matches `docs/target/sidekiq-free.md` (stats flushed on beat).
- Metrics history folds per-class counts in memory, flushes every 5s (`lib/wurk/metrics/accumulator.rb`, `metrics/history.rb` `FLUSH_INTERVAL`).
- A plain job's Redis cost is the 3-command fetch pipeline (`docs/benchmarks.md` floor).

## Files to change
| ID | Where | Today | Change | Risk |
|---|---|---|---|---|
| K1 | `app/controllers/wurk/api/serializers.rb` `stats_payload` (SSE tick + `/api/stats`); `lib/wurk/api/serializers.rb` same shape | ~9 round-trips; `queues` SMEMBERS ×2, `queue:default` LRANGE ×2 | One dashboard snapshot reader, 2 pipelines: (1) stats cmds + SMEMBERS queues/paused/processes; (2) LLEN + LRANGE -1 -1 per queue + HGET busy/info per process. Public `Wurk::Stats` methods unchanged (Sidekiq surface). | none (same keys/commands) |
| K2 | `ApiController#queues` + `QueueConsumers.counts` | 5 trips, polled every 5s | Fold into K1's pipelines | none |
| K3 | `ApiController#queue`, `API::Queues#show` → `queue_gauges`; `lib/wurk/queue.rb` size/latency/paused? | 3 trips (+ LLEN again in paging) | One pipeline LLEN + LRANGE -1 -1 + SISMEMBER; reuse LLEN for paging with 07 A1 | none |
| K4 | `lib/wurk/metrics/history.rb` write/write_class/incr_bucket | EXPIRE per class per bucket key | EXPIRE each shared `j|…` key once per flush | verify Sidekiq metrics flush shape first (inferred) |
| K5 | `ApiController#processes` + `ProcessSet` | GET `dear-leader` is its own trip | Ride the HMGET pipeline | none |
| K6 | `lib/wurk/batch/server_middleware.rb` invalidated HGET per batched job | +1 trip/job | Per-process ~1s cache of invalidated bids | **gated**: changes cross-process visibility of `invalidate_all`; check `docs/target/sidekiq-pro.md` first, human row if it diverges |

Rejected with evidence: caching `SADD queues` per process (breaks queue visibility after a dashboard clear; rides the LPUSH pipeline anyway), caching `const_get` per job (breaks the Rails reloader), per-class option normalization (already memoized). Processor `WORK_STATE` and heartbeat static info stay under 06 P2/P6 (fold `Socket.gethostname` per beat into P6).

## Tests
- Engine round-trip-count tests (one per endpoint) using the 07 A14 counting wrapper: fail on the current trip count, pass at the new one.
- Byte-identical JSON payloads before/after for K1–K3, K5 (golden from the current endpoint).
- `bench/command_count.rb` flush section with 50 classes for K4.

## Done when
- SSE tick ≤ 2 round-trips; `/api/queues` ≤ 2; queue detail ≤ 1 + paging; payloads byte-identical.
- No change to job throughput claims: these cut dashboard/Redis load only.
