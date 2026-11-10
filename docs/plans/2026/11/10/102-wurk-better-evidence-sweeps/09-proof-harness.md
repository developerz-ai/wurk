# 09 — Proof harness: soak/chaos ledger, scale benches, fuzz

> Part of [`overview.md`](overview.md). Depends on: none. T3 lands before [`03`](03-algorithms-scaling.md) rows that cite it.

Why: recent job-loss fixes (`dd5ca20`) were found by "chaos testing, real-store runs and real production deployments" — none of that harness is in the repo. Reaper/private-list parsing is the runtime subsystem with the most fix churn since 2026-09 (`1fcbf3c`, `ac807f1`, `4b66f0a`, `c743bcf`). Existing layers (see `test/CLAUDE.md`): unit, engine, integration (real forks, kill tests, blip + reply-dropping proxies), parity, conformance, ecosystem, `topology` workflow (TLS/ACL/Sentinel on Valkey).

Redis rules (CLAUDE.md Never): no DB 0, no `FLUSHALL`/`SCRIPT FLUSH`; harnesses start their own `redis-server` on a private port (pattern: `bin/rake test:ecosystem`).

## Files to change

| ID | New file | What | Asserts / output |
|---|---|---|---|
| T1 | `bench/soak.rb` + `bench/soak/ledger.rb`, rake `bench:soak` (in `UNGATED_SCRIPTS`), nightly workflow `.github/workflows/soak.yml` (advisory) | Private redis-server (AOF on). `wurkswarm` with N children. Producer enqueues jobs with ledger ids (immediate, scheduled, retrying, batched, unique, limited, cron-fired). Chaos loop: `kill -9` random child, `kill -9` parent + restart, Redis restart from AOF, `TSTP`/`USR1` mid-load. Job body appends `(jid, attempt, pid)` to an append-only file ledger (not Redis). Duration param: 10 min in nightly CI, hours locally. | Zero lost jids; duplicates only inside documented windows (`docs/reliability.md`: deferred-ACK, scheduler double-run) — count reported, bounded; RSS slope ≈ 0 per child (G3); Redis key count flat after drain; dead set contains only deliberate poison jobs. Summary JSON artifact. |
| T2 | `test/unit/private_list_key_fuzz_test.rb` | Property test over generated key shapes: queues containing `\|`, `:`, digits-only; hosts digits-only / with dots / with `\|`-free unicode; pid/nonce widths; legacy pre-nonce shape. | `PrivateListKey.parse_full` ∘ build = identity; `parse_owner` agrees with `parse_full`; a live owner's list is never classified foreign. Seeded, 5k cases, deterministic. |
| T3 | `bench/scale/*.rb`, rake `bench:scale` (ungated) | One script per cliff in [`03`](03-algorithms-scaling.md): `fast_delete` (N ∈ 100k/1M, 1 KB payloads, 0.1% match → max script time, concurrent `LPUSH` p99); reaper sweep (1M filler keys, 1 dead owner, 50 queues → Redis CPU-s per sweep, time-to-reclaim); idle fetch (Q ∈ 50/500, simulated P×C → `commandstats` usec/s, wake latency p50/p99 on queue k); cron register (K ∈ 100/1000 → round trips) + `next_fire_at` ips; limiter waiters (50/500 → EVALSHA/s); scheduled burst (100k due → drain time, RT/job); retry_all (N ∈ 10k/1M → time, RTs, RSS); heartbeat bytes/beat at Q=2000. | Table appended to `docs/benchmarks.md` "Scale" section with date, host, raw data path. Baseline run at `f6f509e` committed before any A-row merges. |
| T4 | `test/integration/poison_race_test.rb` | = R1's test (listed here for the map). | — |
| T5 | `test/integration/command_budget_test.rb` | = P3. | — |
| T6 | `test/integration/redis_restart_test.rb` | Redis process restart (not just proxy blip) under load with AOF: every long-lived thread (heartbeat, scheduler, reaper, leader, cron, flusher, rollups, buffer drainer) alive afterwards; NOSCRIPT recovery exercised (scripts gone after restart). | Thread list unchanged; jobs resume; zero lost from ledger. Check overlap with `redis_outage_recovery_test.rb` first — extend it if it already restarts a real server. |
| T7 | existing: `GlobalConcurrencyTest`, `BatchStepWorkflowTest`, `FetcherReliableTest`, `ScheduledPromotionTest` | Flagged flaky under a shared Redis (`aca53f6` PR body). | Reproduce with `NCPU` high + shared DB; fix isolation per `test/CLAUDE.md` (`WURK_TEST_DB_OFFSET`); replace `sleep` barriers with condition waits. Detail in [`10`](10-code-structure.md) S-tests. |

## Steps
1. PR-a: T2 + T3 baseline (bench scripts + committed baseline numbers).
2. PR-b: T1 harness + nightly advisory workflow. Run 1h locally first; file every finding as its own issue before fixing.
3. PR-c: T6, T7.
4. Any loss/dup found by T1 outranks every other slice — fix in [`01`](01-correctness.md) style (failing test first).

## Tests
- T1 self-test: a deliberately lossy mode (drop ACK'd job) must make the ledger check fail — proves the harness detects loss.
- `bin/check`; soak + scale are never part of `bin/check`.

## Done when
- 1h local soak with chaos: zero lost, bounded dups, flat RSS/key count — numbers in `docs/benchmarks.md` + `docs/reliability.md`.
- Nightly 10-min soak green for 7 consecutive days.
- Baseline + after numbers exist for every A-row merged.
