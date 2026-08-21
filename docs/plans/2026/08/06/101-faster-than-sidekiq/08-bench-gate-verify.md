# 08 — Bench harness, CI gate, final verification

> **Executed; the runner instruction is superseded (2026-08-21).** This plan step predates #430, which
> removed hard-coded runner labels from CI. Step 1's `blacksmith-8vcpu-ubuntu-2404` instruction and its
> "Per CI standard (CLAUDE.md)" citation are stale: `CLAUDE.md` now states runner selection is a
> repository variable (`vars.WURK_BENCH_RUNNER` for bench, `ubuntu-latest` fallback) — do not
> hard-code a runner label on the bench job. `bench.yml` already exists on `main`. Kept unedited
> below as an executed-plan record.

> Part of [`overview.md`](overview.md). Depends on: 02–07 (this is the proof). Do the gate restoration (step 1) FIRST, before any perf commits land, so deltas attribute per commit — it's independent of the other slices.

## Files to change

- `.github/workflows/bench.yml` — restore (deleted in #296, `f9b60e2`).
- `bench/fetch_execute.rb`, `bench/bulk_enqueue.rb`, `bench/memory.rb` — measurement fixes.
- `docs/benchmarks.md` — re-publish numbers; `CLAUDE.md:97` staleness.

## Steps

1. **Restore the regression gate in CI.** `bin/bench-compare` exists and is unit-tested (`test/unit/bench_compare_test.rb`); rule: fail when drop% > base_err% + head_err% + 5 (`bin/bench-compare:69-81,115`), missing-benchmark-on-head also fails (`:99-102`). New `bench.yml`: run `rake bench` on main + PR head, compare, comment delta on the PR. Per CI standard (CLAUDE.md): `blacksmith-8vcpu-ubuntu-2404` (bench SKU — don't downsize), `concurrency` group with `cancel-in-progress: true`, `timeout-minutes` set. It was deleted for cost (#296) — keep it cheap: run only on PRs touching `lib/`, `bench/`, or `Gemfile.lock` (`paths` filter), single run with the existing error-margin logic. Then fix `docs/benchmarks.md:9` / CLAUDE.md:97 wording to match what actually runs.
2. **De-noise `bench/fetch_execute.rb`.** `:52-59` times `client.push` + `processor.process_one` together — enqueue cost pollutes the fetch signal the gate protects. Pre-fill the queue in batches outside the timed block (keep depth ahead of consumption); timed block = `process_one` only. Note in the file that historical numbers reset (bench-compare vs old main will show a spurious jump — land as its own commit, flag in PR).
3. **De-noise `bench/bulk_enqueue.rb`.** `:27` runs LTRIM inside the timed block — move cleanup outside (between iterations via ips' hooks or periodic depth cap outside timing).
4. **Retention probe in `bench/memory.rb`.** Current metric is allocation rate only (`GC.stat(:total_allocated_objects)`, `:51-59`) — a leak scores identically. Add a second reported series: `GC.stat(:heap_live_slots)` delta after N jobs + `GC.start` (majors settled), so 07's fixes are gated. Wire into `bin/bench-compare` output format (a benchmark missing on head fails the gate — add to base first or teach compare about new keys; check `bin/bench-compare:99-102`).
5. **Command-count check.** Script the `INFO commandstats` method from `docs/benchmarks.md:54-64` into `bench/` (e.g. `bench/command_count.rb`, not gated): run 500 noop jobs, print commands/job for wurk and assert ≤2 post-02. Cheap regression tripwire for the whole RTT story.
6. **Final measurement + docs.** After 02–07 land: `bin/rake bench` (gate green) then `bin/rake bench:vs_sidekiq` at 1p×5t and 4p×5t, ≥3 runs, both orders (harness alternates — `vs_sidekiq.rb:250-259`). Update `docs/benchmarks.md`: new table, new commandstats section, boot numbers, dated. Remove the "wurk is currently SLOWER" caveat **only if** every ratio supports it; update CLAUDE.md pillar 3 wording and only then consider README/site/llms.txt claims (per `f4c7d9e` policy).

## Tests

- `test/unit/bench_compare_test.rb` extended for the retention series.
- Workflow: verify on a scratch PR that the comment appears and a synthetic 10% regression fails.
- Full: `bin/rake test && bin/rake test:parity && bin/rake test:ecosystem`.

## Done when

- bench.yml live, commenting deltas, failing >5% regressions.
- fetch_execute times only fetch+execute; bulk times only bulk; memory reports allocation rate AND retention.
- `docs/benchmarks.md` re-published with post-plan numbers; overview "Done when" ratios met (noop/io ≥1.0×, cpu ≥0.95×, boot ≤ Sidekiq).
- Claims in README/site/llms.txt consistent with the published numbers.
