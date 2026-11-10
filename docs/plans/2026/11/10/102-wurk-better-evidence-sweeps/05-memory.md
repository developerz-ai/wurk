# 05 — Memory: bulk ops, fork sharing, recycling, guards

> Part of [`overview.md`](overview.md). Depends on: none. M1 shares code with [`03`](03-algorithms-scaling.md) A8; M10 with A9; M4-Lua with A1 — do each once.

Source: memory sweep. Measured (Ruby 3.4.7, Redis-free): one job through `Processor#dispatch` + default chain = **21 objects / 1,520 B, 0 retained** (null logger); 49 objects with the default formatter. `require "wurk"` = +15.3 MB RSS / +27.7k live objects / +247 features (stock sidekiq 8.1.6: +12.6 MB / +21k / +99). Worker hot path is lean and every in-process cache checked is bounded — the risks are web-process bulk operations, RSS-based recycling, and missing operator tooling. CoW numbers below are **inference** until G4 measures them.

## Files to change

| ID | Pri | Where | Problem | Change |
|---|---|---|---|---|
| M1 | P1 | `lib/wurk/job_set.rb:232-246` `sweep_once` | `::Set` of every jid for a whole `retry_all`/`kill_all` (upstream: O(1) via `pop_each`). 1M entries ≈ 60–100 MB in a web worker (estimate). | Track only entries that failed to leave the set. Do with A8. |
| M2 | P1 | `app/controllers/wurk/api_controller.rb:480-488` `drain_set` | `set.to_a` — whole scheduled set as `SortedEntry` objects for "add all to queue". | Snapshot max score at click; stream `ZRANGE … BYSCORE -inf max LIMIT` pages. Keeps the documented "nothing scheduled after the click" behaviour (comment at `:480`). |
| M3 | P1 | `lib/wurk/metrics/dashboard_series.rb:20-24,92-101,169-172` | Up to 4,320 `HGETALL`s in one pipeline, all replies held at once. | Pipeline in chunks of ~100 keys, fold into totals per chunk. Same result. |
| M4 | P1 | `lib/wurk/swarm.rb:637-665` (`check_memory_pressure`, statm RSS), `lib/wurk/configuration.rb:930-944,1145-1150` | MAXMEM recycling exists (`WURK_MAXMEM_MB`/`SIDEKIQ_MAXMEM_MB`) but: measures RSS (counts pages still shared with parent); no guard when a *fresh* child is already over the limit → recycle loop every ~10s; silent no-op where `/proc` is absent. | (a) Fresh child over limit at first check → ERROR once + slot backoff, no recycle. (b) Boot WARN when limit set and RSS unreadable. (c) Opt-in `WURK_MAXMEM_METRIC=rss\|pss\|uss` via `/proc/<pid>/smaps_rollup`; default `rss` (Ent parity, `docs/target/sidekiq-ent.md` swarm section). |
| M5 | P2 | `lib/wurk/cli.rb:258,331-335` (`warm_up_process`), `lib/wurk/rails_boot.rb:183-208`, `lib/wurk/swarm.rb:193` (`prepare_for_fork!`) | `Process.warmup` only on CLI path, only Ruby ≥3.3 (floor is 3.2), and before `Swarm.new`/`prepare_for_fork!` allocate. | Shared helper called inside `Swarm#boot` after `prepare_for_fork!` (covers railtie path); Ruby 3.2 fallback `GC.start` ×N + `GC.compact if GC.respond_to?(:compact)`; `RUBY_DISABLE_WARMUP=1` still honoured. Keep only if G4 shows lower `Private_Dirty` per child. |
| M6 | P2 | `lib/wurk/heartbeat.rb:149,200,214,246-262` | Every beat re-dumps every in-flight payload + `info`. 25 threads × 1 MB payloads ≈ 25 MB garbage / 10s (estimate). | = A9 memoization. |
| M7 | P3 | `lib/wurk/metrics/accumulator.rb:41-48,86-110` | Redis-outage retention capped by minutes (60) × classes, not entries. | Cap total entries. |
| M8 | P3 | `lib/wurk/client/buffered.rb:23,186-195,307,320` | Outage buffer capped at 1,000 entries, not bytes (1 MB payloads → ~1 GB). | Optional `reliable_push_buffer_bytes` (Wurk-only option; document in `docs/reliability.md`). |
| M9 | P3 | `lib/wurk/queue_consumers.rb:91-96` | `@warned_at` never pruned (dynamic queue names). | Prune with the same `select!` as `@unconsumed_since`. |
| M10 | P3 | `lib/wurk/web/enterprise.rb:46-67` | `SMEMBERS lmtr-list`; swept only when a writable dashboard lists it → grows with dynamic limiter names if nobody opens the page. | Leader-gated periodic sweep reusing `limiter_list_sweep.lua`; GET becomes read-only (= [`06`](06-dashboard-api.md) W6). |
| M11 | P3 | `docs/deployment.md:154-157,550` | Doc: sizing formula omits the N+1 child during recycle/rolling restart (`lib/wurk/swarm/restart.rb:99-110` forks replacement before TERM); says "pages × 4KB" (code uses host page size, `heartbeat.rb:79`). No allocator guidance anywhere (`grep jemalloc\|MALLOC_ARENA_MAX\|RUBY_GC_ docs` = 0). | Fix formula; add "Memory tuning": `MALLOC_ARENA_MAX=2`, jemalloc, YJIT cost, `redis_idle_timeout` (default nil = idle connections never closed, `configuration.rb:51`), MAXMEM metric choice. Default-on idle timeout = H5. |
| M12 | P3 | `lib/wurk/client.rb` (push path) | No payload-size warning. | Opt-in client middleware: WARN above N bytes (class, jid, size). No wire change. |

## Guards (new — nothing like them exists; `bench/memory.rb` needs Redis and uses a null logger)

| ID | File | What | Flake control |
|---|---|---|---|
| G1 | `test/unit/allocation_budget_test.rb` | Redis-free (dead-port URL): 200 warm-up + 1,000 jobs through `Processor#dispatch`/`execute_job`; assert `GC.stat(:total_allocated_objects)` delta ≤ budget+2. Cases: null logger (21), Pretty formatter on real IO (49), failing job on retry path. | Deterministic per Ruby minor → budgets keyed by `RUBY_VERSION[0,3]` (compat leg runs 3.2). |
| G2 | `test/unit/boot_footprint_test.rb` | Subprocess `require "wurk"`: `$LOADED_FEATURES` delta and live-object delta within 10% of pinned; after P6: `!defined?(Rack::Builder)`. RSS reported, not asserted. | Subprocess isolates from suite state. |
| G3 | `bench/memory.rb` extension + bounded-cache unit tests | Real logger, 10% failing jobs, 100k jobs; report slope of `heap_live_slots` + RSS over the last half. Unit: 10k dynamic queues/limiters/classes → container sizes bounded (M7, M9). | Bench advisory; unit tests exact. Feeds [`09`](09-proof-harness.md) T1 soak. |
| G4 | `bench/swarm_memory.rb` (Linux) | Preload dummy app, fork 4 idle children, read `smaps_rollup` `Pss`/`Private_Dirty` at fork and +30s. Decides M5; baseline for M4(c). | Advisory; add to `UNGATED_SCRIPTS`. |

## Steps
1. PR-a: G1 + G2 (pin today's numbers).
2. PR-b: M1 (with A8), M2, M3 — web-process bulk paths.
3. PR-c: M4 + G4 + M5 (M5 kept only on G4 evidence).
4. PR-d: M7, M8, M9, M12; M10 with W6; M11 docs.
5. `bin/repin-anchors` per PR; `bin/check`.

## Tests
- M1/M2: integration, 20k-entry set — allocations during sweep O(page), result count unchanged, entries added after the click untouched (M2).
- M3: unit — `CommandSpy` max pipeline size ≤ chunk; output equal to unchunked on a fixture.
- M4: unit with stubbed RSS/smaps reader — fresh-over-limit → 0 recycles + 1 ERROR; `pss` metric path; existing `test/integration/swarm_boot_test.rb:175` (1 MB limit) must be rewritten to "limit crossed after boot" since (a) changes its premise.
- G1–G3 are the tests.

## Done when
- No dashboard/API action loads a whole user-growable set into Ruby memory (list of bounded paths in `docs/dashboard.md`).
- A limit below fresh-child RSS yields one ERROR, not a fork loop.
- CI fails on +3 objects/job or +10% boot features.
- `docs/deployment.md` has measured per-child `Private_Dirty` numbers from G4 and the corrected sizing formula.
