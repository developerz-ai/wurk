# 02 — Fetch, ack, metrics: 4 RTT/job → ~1

> Part of [`overview.md`](overview.md). Depends on: 01 (map) and [`00-semantics-signoff.md`](00-semantics-signoff.md) — read its "Required to hold" lists before writing code; they are conditions of acceptance, not advice. This slice moves the headline noop ratio.

## Files to change

- `lib/wurk/fetcher/reliable.rb` — paused cache, ack piggyback, allocation diet.
- `lib/wurk/metrics/history.rb` — in-process aggregation + timer flush.
- `lib/wurk/launcher.rb` or the History component — flush wiring (only if History can't self-flush via its existing `TimerLoop`).

## Steps

1. **Paused-set cache (P1b).** `queues_cmd` (`reliable.rb:151-156`) calls `paused_names` (`:197` — `SMEMBERS` + `Set.new`) every fetch attempt. Cache the Set per fetcher with a monotonic-clock TTL (~2s, constant). Busy path: 1 RTT/job removed. Keep a forced refresh on pause/unpause API calls in-process (`Wurk::Queue#pause!` side) so local actors see it immediately; cross-process latency ≤ TTL — document as intentional divergence. If a later re-measure still needs the fetch RTT gone entirely, escalate to P1a (Lua script folding paused-check + LMOVE walk into one EVALSHA) — keep key/format identical.
2. **In-process `Metrics::History` aggregation (P2b).** Today `record` (`history.rb:73-81`) pipelines 6 commands per job (`:86-101`). Replace with a mutex-guarded in-memory accumulator `{[class, minute_bucket] => {processed:, failed:, ms:}}` flushed every ≤5s by the component's existing timer loop: one pipeline, same `HINCRBY`/`EXPIRE` commands, same keys/fields (HINCRBY is additive — wire-identical). Flush on `stop` too (drain, in an `ensure`). Also P2a: memoize `minute_key`/`hour_key` (`:105-114`) per bucket rollover and the per-class field-name strings — the accumulator keying largely subsumes this.
3. **Ack piggyback — the reliable-fetch answer to no-ack BRPOP.** `acknowledge` (`reliable.rb:56-67`) is 1 RTT/job. Change `retrieve_work` busy path: keep the completed job's ack pending in the fetcher (per-thread), and on the **next** fetch send one pipeline: `LREM <private> 1 <prev-json>` + (`DEL super_fetch:recovered:<prev-jid>` — see step 4) + non-blocking `LMOVE`. Busy queue: 1 RTT total/job. Empty result → flush pending ack immediately, then park in `BLMOVE` as today (blocking calls can't join a pipeline). Also flush pending ack on processor stop/terminate (`ensure`). Redelivery window widens from "post-job" to "next fetch or shutdown flush" — same at-least-once class; document for parity, add divergence note.
4. **Conditional recovered-key DEL.** The `DEL super_fetch:recovered:<jid>` (`reliable.rb:61-66`) is only meaningful for jobs that were reclaimed by the reaper. Verify: if `UnitOfWork` can know it came from a recovery path (flag set where the reaper requeues), skip the DEL for the ~100% normal case. If the key existence can't be known client-side, keep it — it rides the same pipeline anyway after step 3.
5. **Allocation diet in the fetch path** (all P3/P8): memoize `Socket.gethostname` + the private-list name at fetcher init with a `Process.pid` guard for fork safety (`reliable.rb:89-92`); prebuild the strict-mode queue array + frozen `"queue:#{q}"` strings once (weighted mode keeps shuffle — match Sidekiq `fetch.rb:79-87`: strict path allocation-free); store `queue_name` on `UnitOfWork` at build instead of `delete_prefix` per job (`:70`).

## Tests

- Existing: `test/unit/fetcher_reliable_test.rb`, `test/unit/metrics_history_test.rb`, `test/integration/reaper_kill9_test.rb` (proves reclaim still works with deferred ack — the kill-9 window is exactly what changed), `test/integration/graceful_shutdown_test.rb` (ack flush on drain).
- New: paused-cache TTL behavior (pause visible ≤ TTL, immediate in-process); History accumulator flush correctness (sums equal per-job writes; flush on stop; keys/fields byte-identical — assert against real Redis); pending-ack flush on empty fetch, on terminate, and single-LREM-per-job (count via `INFO commandstats` or command spy on the adapter).
- Parity: `bin/rake test:parity` — any divergence must be documented per CLAUDE.md.
- Bench: `bin/rake bench:fetch_execute` before/after each step (commit per step so deltas attribute); final `bin/rake bench:vs_sidekiq`.

## Done when

- Busy-queue steady state ≤2 Redis commands/job measured via the `INFO commandstats` method (`docs/benchmarks.md:54`), down from ~10.
- noop ratio moves materially (expected into ≥0.8× territory before slice 03).
- kill-9 reclaim, graceful drain, pause/unpause integration tests green; parity green; coverage ≥90/90.
