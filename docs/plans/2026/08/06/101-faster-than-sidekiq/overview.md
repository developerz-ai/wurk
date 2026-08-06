# Faster than Sidekiq

## Goal

Close the wurk-vs-Sidekiq gap (noop 0.45×, io 0.66–0.74×, cpu 0.81–0.86×, boot 0.97s vs 0.67s — `docs/benchmarks.md`) and get every `rake bench:vs_sidekiq` ratio ≥ 1.0×. Root cause is known and measured: wurk spends ~4 Redis round trips / ~10 commands per job vs Sidekiq's 1, plus a heavier per-job Ruby dispatch. Secondary goals folded in per maintainer request: fix memory/resource-lifecycle defects (leaks, missing `ensure`) and stop per-job reallocation in hot loops.

## Context

- Ruby gem, Sidekiq drop-in. **Wire-compat is sacred** — no Redis key / JSON field / score format changes (`CLAUDE.md`). Parity tests (`test/parity/`) are oracles. Coverage gate ≥90% line+branch on `lib/`. Reliable BLMOVE fetch is the default — no basic-fetch mode.
- **The headline number is fetch-side only.** `bench/vs_sidekiq.rb:117-128` pre-RPUSHes payloads; enqueue cost is off the clock. Enqueue work moves only `rake bench` (regression gate), not the ratio.
- Stock Sidekiq 8.1.2 source for reference: `~/workspace/developerz-ai/venom.is/rails/vendor/bundle/ruby/3.4.0/gems/sidekiq-8.1.2` (bench Gemfile pins `>= 8.0`, no lockfile). Its per-job Redis cost is **one BRPOP, zero ack, zero stat writes** — stats flush per 10s heartbeat (`launcher.rb:118-139` there).
- Prior audit: `docs/plans/2026/07/31/101-leak-logic-perf-fixes/` is 82% done; its slice `08-perf-quick-wins.md` (items P1–P13) is 0% and is **absorbed by this plan** — P-numbers are cross-referenced in the slices here. Executor may mark that slice superseded in its status.yml.
- The >5% bench regression gate (`bin/bench-compare`) has **no CI workflow** — deleted in #296 (`f9b60e2`). CLAUDE.md:97 and `docs/benchmarks.md:9` are stale on this. Restore before landing perf commits so deltas are attributed per commit.

## Plan files (execute in order)

1. [`01-hotspot-map.md`](01-hotspot-map.md) — reference map: every measured hotspot with file:line. No code changes.
2. [`02-fetch-ack-metrics.md`](02-fetch-ack-metrics.md) — the headline fix: 4 RTT/job → ~1 (paused-set cache, in-process metrics aggregation, ack piggyback). `fetcher/reliable.rb`, `metrics/history.rb`.
3. [`03-processor-dispatch.md`](03-processor-dispatch.md) — per-job Ruby cost: chain traverse, tid/context/logger allocations. `processor.rb`, `middleware/chain.rb`, `job_logger.rb`.
4. [`04-enqueue-client.md`](04-enqueue-client.md) — enqueue + bulk/batch: single verify_json, statsd guard, hash-merge diet, batch pipelining. `client.rb`, `job_util.rb`, `metrics/statsd.rb`.
5. [`05-redis-layer-pools.md`](05-redis-layer-pools.md) — per-command adapter tax, checkout frames, timeout padding, pool reuse. `redis_pool.rb`, `redis_client_adapter.rb`, `pool_checkout.rb`.
6. [`06-boot-swarm.md`](06-boot-swarm.md) — boot 0.97s → ≤0.67s: pre-fork Lua load, deferred pollers, CoW warmup. `swarm.rb`, `swarm/child_boot.rb`, `launcher.rb`.
7. [`07-leaks-raii.md`](07-leaks-raii.md) — leak/lifecycle fixes: zombie reaping, unbounded joins, missing ensure, append-only registries.
8. [`08-bench-gate-verify.md`](08-bench-gate-verify.md) — restore CI gate, de-noise bench harness, add retention probe, re-measure, update docs.

Slices 02–07 touch disjoint files (per CLAUDE.md: no worktrees; parallel agents must not share files). 07 edits `swarm.rb`/`launcher.rb` after 06 — run sequentially or coordinate. 08 last.

## Done when

- `rake bench:vs_sidekiq`: noop ≥1.0×, io ≥1.0×, cpu ≥0.95× (cpu is ±24–33% noisy), boot-to-first-job ≤ Sidekiq's, at both 1p×5t and 4p×5t.
- Per-job Redis commands on busy queue ≤2 (verify with `INFO commandstats` method from `docs/benchmarks.md:54`).
- `rake bench` gate green (no >5% regression vs main on enqueue/bulk/fetch+execute/swarm-boot/memory).
- Bench CI workflow restored and commenting deltas on PRs.
- All 07 leak findings fixed or explicitly waived with a written reason.
- `bin/rake test`, `test:parity`, `test:ecosystem` green; coverage ≥90/90.
- `docs/benchmarks.md` re-published with new numbers. "Faster" claims in README/site/llms.txt only if the numbers say so (CLAUDE.md pillar 3).

## Risks / open questions

- **Semantics sign-offs needed** (all wire-compat-safe, all behavior-visible; decide before 02):
  - `Metrics::History` in-process aggregation + ≤5s flush (P2b): dashboard minute-buckets lag up to flush interval. Recommendation: do it — it's 6 of the ~10 commands/job and `docs/benchmarks.md:99` already names it as the fix.
  - Paused-set cache (P1b, TTL ~2s) or Lua-folded fetch (P1a): queue pause takes effect within TTL instead of next fetch. Recommendation: P1b first, P1a if still short.
  - Deferred ack piggyback (02 step 3): widens the at-least-once redelivery window from "ack after job" to "ack on next fetch / ≤100ms flush". Same guarantee class; must be documented as intentional divergence for parity.
- Middleware **instance caching stays rejected** (per-job-fresh is the documented Sidekiq contract, `middleware/chain.rb:10-12`); 03 only cheapens construction/traverse. `Object.const_get` memoization stays rejected (Rails reloading).
- cpu workload may stay <1.0× at 1 process — it's GVL-bound in both; wurk's win there is the swarm story, not per-thread. Don't chase it with unsafe changes.
- If noop is still <1.0× after 02+03: remaining gap is dispatch-onion depth (`processor.rb:211-228`, 7 frames + 6-entry chain vs Sidekiq's ~1). Escalation options (conditional registration of no-op built-ins) need their own sign-off — drop-in contract review.
