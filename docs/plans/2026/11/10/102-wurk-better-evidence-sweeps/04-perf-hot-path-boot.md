# 04 — Per-job CPU + boot time

> Part of [`overview.md`](overview.md). Depends on: none. Measurement (P1) gates every other row.

State (`docs/benchmarks.md`): Wurk 0.87x–1.02x of stock Sidekiq; behind on noop + boot. Sweep finding by reading: both sides make 2 round trips per noop job (wurk: `LREM+DEL+LMOVE` pipelined, `lib/wurk/fetcher/reliable.rb:421-433`, `lib/wurk/fetcher/unit_of_work.rb:77-82`; stock: `BRPOP`). **Inference, unmeasured:** the gap is Ruby work — 8 server middleware built per job (`lib/wurk.rb:338-361`, `lib/wurk/middleware/chain.rb:209-213`), 7 dispatch frames (`lib/wurk/processor.rb:426-443`), ~6 mutex acquisitions. No single hot spot visible by reading → profile first, no guessed optimizations. No "faster" claim anywhere until `docs/benchmarks.md` supports it (CLAUDE.md pillar 3).

## Files to change

| ID | Where | Change | Proof |
|---|---|---|---|
| P1 | `bin/profile`, `bench/vs_sidekiq.rb`, `bench/vs_sidekiq/` | Add a stock-Sidekiq mode to `bin/profile` (same noop job, same Redis, same Ruby/YJIT flags); run CPU + `--alloc` on both; attribute the gap per frame. Commit raw output under `bench/results/` (or wherever `docs/benchmarks.md` already points). | The profile itself; a table "frame → % of gap" in `docs/benchmarks.md`. |
| P2 | `.github/workflows/bench.yml` (new scheduled job) | Weekly `bin/rake bench:vs_sidekiq` on a quiet hosted runner; upload raw data as artifact + append to a results file via PR (no direct push to `main`). Advisory, never required. | Workflow green; see `.github/CLAUDE.md` for the bench lane rules. |
| P3 | new `test/integration/command_budget_test.rb`; `bench/command_count.rb` (currently in `UNGATED_SCRIPTS`, `Rakefile:156`) | Drive `Processor#process_one` over N noop jobs with the full default chain + `Wurk::Test::CommandSpy`; assert ≤3 commands / 1 round trip per job. A middleware adding a Redis call per job fails CI. | Test red if a per-job command is added. |
| P4 | `lib/wurk/middleware/chain.rb:145,209-213`, built-in middleware (Expiry, InterruptHandler, Limiter::ServerMiddleware, Metrics::History, Statsd, Status, Batch::ServerMiddleware, Timeout) | Only if P1 attributes ≥3% to chain construction: built-in stateless middleware opt into one cached instance per chain entry (`shared_instance?`); user middleware still instantiated per job (Sidekiq contract). Audit each built-in for per-call ivar writes first. | `bin/rake bench` noop + [`05`](05-memory.md) G1 allocation budget (21 → ~13 objects/job). |
| P5 | `lib/wurk/logger.rb:34-44` | Formatter: single `+''` buffer instead of `map/join`; cache `pid=` per pid. Output bytes identical. Measured by memory sweep: 28 of 49 objects/job with the default formatter on a real IO. | G1 budget (49 → ≤35); formatter unit tests byte-equal. |
| P6 | `lib/wurk.rb:8-81,287-385` (eager requires), `lib/wurk/compat.rb` | Boot: `require "wurk"` loads 158 own files / 247 features vs stock 20 own / 99 (measured, Redis-free). `autoload` for `Wurk::Web` (+ `rack/builder`), `Metrics::Query`, `DashboardSeries`, `Metrics::Prometheus`, `Flow`/`FlowSet`, `Client::Buffered`, `Health`, `API::Fast`, iterable CSV/AR enumerators. Middleware that self-registers at load stays eager. `Sidekiq::*` aliases must still resolve lazily (`compat.rb:236` `const_missing` is the hook). | [`05`](05-memory.md) G2 boot test: feature count down, `!defined?(Rack::Builder)`; `bench/swarm_boot.rb`; `vs_sidekiq` boot row. |
| P7 | `lib/wurk/cli.rb:211,413` | Boot issues `INFO` twice (`BootChecks.run`, `validate_redis!`) → read once, pass through. | `CommandSpy` unit: one `INFO` per boot. |
| P8 | `lib/wurk/fetcher/unit_of_work.rb` (`keyword_init` Struct), `lib/wurk/metrics/statsd.rb:199-211`, `lib/wurk/metrics/histogram.rb` (`BUCKET_INTERVALS.index` linear) | Micro: positional Struct init; statsd tags built once per (class, queue); `bsearch` bucket. Only with P1 evidence. | G1 budget. |

## Steps
1. P1, P2, P3 in one PR (measurement + guard, no runtime change).
2. P6 + P7 (boot) — own PR; run `bin/rake test:ecosystem` (third-party gems reference constants at load).
3. P5, then P4/P8 strictly per P1 attribution. A row with <1% attributed gain is dropped and noted in `status.yml`.
4. After each PR: rerun `bin/rake bench:vs_sidekiq` on a quiet host; update `docs/benchmarks.md` numbers only from raw data committed in the same PR.

## Tests
- P3 as above; P6: `test/unit/` subprocess test (`ruby -Ilib -e 'require "wurk"; …'`) asserting lazy constants unloaded and each resolves on first reference incl. via `Sidekiq::Web`.
- `bin/rake test:parity`, `bin/rake test:ecosystem`, `bin/check`, `bin/rake bench`.

## Done when
- `docs/benchmarks.md` has a per-frame attribution of the noop gap and a dated re-run with raw data.
- Boot-to-first-job gap vs stock measured before/after P6/P7.
- CI fails on any added per-job Redis command or allocation regression.
- README/site/llms.txt speed wording unchanged unless the doc's numbers support a change.
