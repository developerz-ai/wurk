# 01 — Hotspot map

> Part of [`overview.md`](overview.md). Depends on: none. **Reference only — no code changes.** Every other slice cites this map.

## Benchmark ground truth

wurk 1.4.0 vs sidekiq 8.1.6, ruby 3.4.9, median of 3 × 4000 jobs (`docs/benchmarks.md`):

| Workload | 1p×5t ratio | 4p×5t ratio |
|---|---|---|
| noop | **0.45×** | **0.49×** |
| cpu | 0.81× | 0.86× |
| io | 0.74× | 0.66× |
| boot-to-first-job | 0.97s vs 0.67s | — |

noop = pure framework overhead = the honest signal. Driver pre-RPUSHes payloads (`bench/vs_sidekiq.rb:117-128`) → ratio measures fetch+dispatch+ack+metrics only.

## Per-job Redis cost, busy queue (the 0.45×)

Sidekiq: **1 round trip, 1 command** (BRPOP; ack is a no-op — `sidekiq-8.1.2/lib/sidekiq/fetch.rb:16-18`; stats are in-memory counters flushed per 10s beat).

Wurk: **4 round trips, ~10 commands**, all on the main pool:

| # | Commands | Where | Fixed by |
|---|---|---|---|
| 1 | `SMEMBERS paused` | `lib/wurk/fetcher/reliable.rb:197` (per fetch attempt, via `queues_cmd:153`) | 02 (P1b/P1a) |
| 2 | `LMOVE queue:<q> <private>` | `lib/wurk/fetcher/reliable.rb:209` | keeps (reliable-fetch feature) — folded into 1 RTT by 02 |
| 3 | 6 cmds pipelined: `HINCRBY`×2 + `EXPIRE` × minute/hour buckets | `lib/wurk/metrics/history.rb:86-101` (wraps every job, `:47-65`) | 02 (P2b) |
| 4 | `LREM <private> 1 <full-json>` + `DEL super_fetch:recovered:<jid>`, pipelined | `lib/wurk/fetcher/reliable.rb:56-67` | 02 (piggyback) |

Extra: LREM's needle is the entire job JSON — O(list-len × payload) server-side + payload re-shipped on the wire.

## Per-job Ruby cost (allocation / syscall hotspots)

| Hotspot | Where | Note |
|---|---|---|
| `Socket.gethostname` syscall ×2/job + 5-part interpolated string ×2 | `lib/wurk/fetcher/reliable.rb:89-92` (called `:208`, `:57`) | P3 → 02 |
| `queues_cmd`: `shuffle`+`uniq`+`reject`+`map` + `"queue:#{q}"` strings per fetch | `lib/wurk/fetcher/reliable.rb:151-156` | P8 → 02 |
| `Set.new(SMEMBERS reply)` per fetch; `delete_prefix` per job | `lib/wurk/fetcher/reliable.rb:197`, `:70` | 02 |
| Middleware chain: 6 fresh instances + `respond_to?(:config=)` ×6 + traverse lambda + `Array#shift` ×6, per job | `lib/wurk/middleware/chain.rb:75-99`, `:120-123` | P4 → 03 |
| Default server chain = **6 entries** (InterruptHandler, Batch, Expiry, Limiter, Statsd, History); 5 no-op for a plain job. Sidekiq CLI runs ~1 | registrations: `middleware/interrupt_handler.rb:46`, `batch/server_middleware.rb:98`, `middleware/expiry.rb:50`, `wurk.rb:297,305,312` | 03 |
| Dispatch onion: 7 nested blocks + 2 `Thread.handle_interrupt` before perform | `lib/wurk/processor.rb:211-228`, `:175-177` | 03 |
| `stats`: `tid` recomputed per job + `Time.now.to_i` + 4 mutex acquisitions | `lib/wurk/processor.rb:249-260` | P7 → 03 |
| `JobLogger#prepare`: context Hash + `logged_job_attributes` walk; `Context.with` merges 2 hashes | `lib/wurk/job_logger.rb:43-60`, `lib/wurk/context.rb:15-21` | P9 → 03 |
| `Metrics::History`: `Time.now.utc.strftime` ×2 + 3 field-name interpolations per job | `lib/wurk/metrics/history.rb:105-114` | P2a → 02 |
| `verify_json` runs **twice** per push (recursive args walk ×2) | `lib/wurk/client.rb:62` + `:143` | P6 → 04 |
| `emit_enqueued`: 2 tag strings + Array per payload even with no statsd client; `Statsd.client` re-resolves config every call | `lib/wurk/client.rb:439-447`, `lib/wurk/metrics/statsd.rb:94-101` | P5/P13 → 04 |
| `normalize_item`: ≥2 hash merges per job | `lib/wurk/job_util.rb:50-56`, `:95-98` | 04 |
| Batched (`bid`) enqueue: 1 EVALSHA RTT **per job**, unpipelined | `lib/wurk/client.rb:379-391` | 04 |
| `CompatClient` decorator: extra frame + `@round_trips += 1` on **every** Redis command (×10/job); Sidekiq's adapter has no odometer | `lib/wurk/redis_client_adapter.rb:69`, `:100-113` | 05 |
| `RedisPool#run` snapshot + rescue frame, `PoolCheckout.with` frame + `is_a?` — per checkout, ×4/job | `lib/wurk/redis_pool.rb:191-209`, `lib/wurk/pool_checkout.rb:23-27` | 05 |
| Manual `timeout+1` read-timeout padding duplicates redis-client's own (`connection_mixin.rb:85-91`) | `lib/wurk/fetcher/reliable.rb:222` | 05 |

## Boot (0.97s vs 0.67s)

| Hotspot | Where |
|---|---|
| Every child re-uploads all Lua scripts (SCRIPT LOAD is server-global) | `lib/wurk/swarm/child_boot.rb:133-138` — P11 → 06 |
| Launcher starts **6 background loops before managers**: heartbeat, scheduled poller, leader, cron poller, metrics rollup ×2/history. Sidekiq starts ~2 | `lib/wurk/launcher.rb:63-75`, `:88-102` → 06 |
| Sequential fork loop, `close_supervisor_pool` before each fork | `lib/wurk/swarm.rb:246-248`, `:269` → 06 |
| No `Process.warmup` pre-fork | Sidekiq: `cli.rb:106` → 06 |

## Sidekiq tricks to match (source: sidekiq-8.1.2, see overview for path)

Per-beat stat flush (`launcher.rb:118-139`) · empty-chain short-circuit (`middleware/chain.rb:170`) · single pipelined RTT even for 1 push (`client.rb:259`) · push_bulk normalizes once, 1000-slices, varargs LPUSH (`client.rb:157-176`, `:291-297`) · `clock_gettime(REALTIME, :millisecond)` not `Time.now` (`job_util.rb:65-67`) · identity-dispatch lambda table for arg verify (`job_util.rb:80-111`) · `USED_COMMANDS` real methods dodge method_missing (`redis_client_adapter.rb:23-37`) · memoized static heartbeat JSON (`launcher.rb:255-281`) · frozen `handle_interrupt` hashes (`processor.rb:161-164`) · thread priority -1 (`component.rb:19,44-48`) · `Process.warmup` + freeze before threads (`cli.rb:103-110`).

Sidekiq is genuinely beatable at: `Object.const_get` per job (they don't cache; we also can't — Rails reloading) and its own non-empty CLI chain + per-job chain instantiation — wurk wins by making chain traversal cheaper (03), not by caching instances.

## Leak / lifecycle map

See [`07-leaks-raii.md`](07-leaks-raii.md) findings table. Headline: `Process.wait2(-1)` steals host children in embedded mode (`swarm.rb:357`); unbounded joins in reaper/leader stop (`fetcher/reaper.rb:99`, `leader.rb:145`); `WORK_STATE.set` outside its ensure (`processor.rb:250`); append-only `on_poison` registry (`middleware/poison_pill.rb:132-137`).

## Bench-harness dilution (fix in 08)

- `bench/fetch_execute.rb:56-57` times a full enqueue inside the fetch+execute loop.
- `bench/bulk_enqueue.rb:27` times an LTRIM inside the bulk-enqueue block.
- `bench/memory.rb:51-68` measures allocation rate only — retention is invisible.
- Regression gate `bin/bench-compare` has no CI workflow (deleted #296).
