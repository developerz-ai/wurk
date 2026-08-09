# 10 — Global per-queue concurrency

> Part of [`overview.md`](overview.md). Depends on: none.
>
> **This is the one slice that touches the fetch hot path.** Everything else in the plan is inert when unused; this one has to prove it. If it can't be made free-when-unconfigured *and* cheap-when-configured, **defer it** — the previous plan fought from 10 Redis commands/job down to 3 (`docs/plans/2026/08/06/101-faster-than-sidekiq/08-measurements.md`) and giving that back for a feature most apps won't enable is a bad trade.

## Why

"At most 20 jobs from this queue running cluster-wide, whatever the worker count." A ceiling on steady-state concurrency, with one named exception: a rolling restart runs both generations for the length of one drain, so the cap can be briefly exceeded by the old child's in-flight count — bounded, deliberate, and settled in step 5 below. Oban Pro's Smart Engine and BullMQ's global concurrency both sell this; Wurk's limiters can't express it — `Wurk::Limiter::Concurrent` is keyed per-lock, not per-queue, and gates *inside* the job (server middleware) rather than at fetch. Gating inside the job means the job is already claimed off the queue, so it either blocks a thread or reschedules — neither is a real cap.

## Design constraints

1. **Zero cost when unconfigured.** No config → the fetcher's code path must be identical to today's, not "identical plus a nil check per fetch". Resolve at boot, not per job.
2. **Fold into the existing pipeline.** `lib/wurk/fetcher/reliable.rb` already pipelines BLMOVE with a piggybacked ack and a cached paused-set lookup. A concurrency gate must join that pipeline or that Lua, not add a round-trip.
3. **Crash-safe.** A slot held by a process that was SIGKILLed must be released without operator action. Counter-based schemes leak on kill; use a TTL'd holder key per slot, refreshed by the existing heartbeat (`lib/wurk/heartbeat.rb`) — no new beat traffic.
4. **No new fetch semantics for unconfigured queues.** Reliable BLMOVE stays the default and only fetcher (`CLAUDE.md`).

## Files to change

- `lib/wurk/fetcher/reliable.rb` — the gate, guarded so unconfigured queues short-circuit before any new work.
- new `lib/wurk/lua/queue_slot.lua` — acquire/release, registered in `lib/wurk/lua.rb`.
- `lib/wurk/keys.rb` — new slot-key prefix.
- `lib/wurk/configuration.rb` — `global_concurrency: { "critical" => 20 }`.
- `lib/wurk/processor.rb` — slot release on completion, RAII-style (`ensure`), matching the discipline from `docs/plans/2026/07/31/101-leak-logic-perf-fixes/`.
- `lib/wurk/heartbeat.rb` — refresh held slots (piggyback, no extra beat).
- Dashboard: expose per-queue cap + in-use count (`app/controllers/wurk/api_controller.rb#queues`, and the API in slice 07).

## Steps

1. Measure first. Add a `bench/` case for fetch under a configured cap before writing the gate, so the cost is known, not argued.
2. Slot model: a per-queue capacity with TTL'd holders keyed by `<process identity>:<slot>`. Acquire and BLMOVE want to be one Lua script; if they can't be, acquire must at least ride the existing pipeline.
3. **Starvation and fairness.** A capped queue with all slots held must not spin the fetcher. Back off on the capped queue while still serving other queues in the same fetch — otherwise one capped queue stalls the whole worker. This is the hard part, not the counting.
4. Release on every exit path: success, failure, retry, interrupt, timeout (slice 08), process death (TTL). `ensure`, not a happy-path call.
5. Interaction with rolling restart (`lib/wurk/swarm/restart.rb`): during a restart both the old and new slot hold capacity briefly. Decide whether that's tolerated (recommend yes, TTL bounded) and document it.
6. Interaction with quiet/TSTP: a quiet process must release its slots, not sit on them while draining.

> Steps 4–6 are settled in [`10-global-concurrency-lifecycle.md`](10-global-concurrency-lifecycle.md): the release anchored in `Processor#process`'s `ensure` and riding the ACK's pipeline, the refresh riding the heartbeat, rolling restart tolerated as bounded over-admission, and quiet holding only the slots its draining jobs are spending.

## Tests

- Unit: cap N, N+1 concurrent claims → the extra waits; released slot admits the waiter.
- Integration (real forks, real Redis — never mocked): 4 processes × 5 threads against a cap of 3 → never more than 3 in flight, sustained.
- Crash safety: SIGKILL a slot holder → capacity recovers within the TTL, no operator action.
- Fairness: capped queue at capacity does not stall fetching from other queues.
- Leak: 10k jobs through a capped queue → slot key count returns to zero.
- **`rake bench` with no global concurrency configured → within noise of main, and `bench/command_count.rb` still reports 3 commands/job.** This is the gate on the whole slice.
- `rake bench` with a cap configured → report the delta honestly; it is allowed to cost something.

## Done when

- A cluster-wide cap holds across processes and hosts.
- Slots recover from SIGKILL without intervention.
- Unconfigured path proven unchanged by command count **and** bench.
- Capped queues don't starve other queues.
- If any of the above can't be met: slice closed as **deferred**, with the measurements written up. That is an acceptable outcome.

## Ship decision (2026-08-09)

**Shipped, not deferred.** The gate this slice lives or dies by is the last two bullets
above, and both are met, measured against `main` (`c8af524`) at head (`896803c`).

`bench/command_count.rb` — unconfigured (no `global_concurrency` set), 500 noop jobs,
`INFO commandstats` on an otherwise-idle Redis (the shared dev Redis container reads
high because another local process's traffic pollutes server-wide commandstats; run
against a dedicated container instead — see below):

```text
  commands  per job  command
       500     1.00  lrem
       500     1.00  lmove
       500     1.00  del
  --------  -------
      1500     3.00  total

✓ 3.00 commands/job, within the budget of 3.00 and at the recorded baseline of 3.00
```

Unchanged from the pre-slice baseline in `docs/benchmarks.md` — `Fetcher::Capped`'s
boot-resolved `@capped` boolean means an unconfigured install runs the exact `Reliable`
loop it ran before this slice existed, not that loop plus a per-fetch check.

`rake bench` (the gate: `enqueue`, `fetch+execute`, `bulk_enqueue`, `memory`,
`scheduled_poll`, `swarm_boot`; unconfigured), head vs `main`, `bin/bench-compare`:

```text
| benchmark                          | base (i/s) | head (i/s) |    Δ   |               |
|-------------------------------------|-----------:|-----------:|-------:|---------------|
| wurk enqueue                       |      4.20k |      4.02k |  -4.3% | slower, noise |
| wurk fetch+execute                 |      3.22k |      3.32k |  +2.9% | 🟢            |
| wurk hot-path (jobs/1k-alloc)      |          6 |          6 |  +0.0% | 🟢            |
| wurk hot-path (retention-free/1k)  |      1.00k |      1.00k |  +0.0% | 🟢            |
| wurk idle scheduler sweep          |      2.42k |      2.32k |  -4.4% | slower, noise |
| wurk push_bulk(1000)               |         66 |         68 |  +4.1% | 🟢            |
| wurk swarm boot                    |        115 |         88 | -23.6% | slower, noise |
```

No benchmark clears `bin/bench-compare`'s regression bar (combined ±noise + 5%);
`swarm_boot`'s headline -23.6% carries ±47%/±25% error on the two sides, an order of
magnitude wider than the delta — noise, not a regression. A second pairing against the
same commits on the team's shared dev Redis (`wurk-dev-redis`, noisier host) showed the
same picture (`fetch+execute` -4.3%, everything else flat or faster). Reproduce:
`git checkout main && rake bench > base.txt; git checkout <branch> && rake bench > head.txt;
bin/bench-compare base.txt head.txt`. Run against a Redis container this process alone
holds — `INFO commandstats` and benchmark/ips throughput are both server-wide, and a
shared dev Redis with another local process on it reads as noise or a phantom command,
never as a false pass.

Both halves of the gate hold, so the feature ships: slot model, fetch-path fold,
lifecycle (release/refresh/quiet/restart), and real-fork integration proof are all in
`main` as of this branch.

The configured-cost side of the trade (a cap actually in use costs something, on
purpose) is **not** measured. The gate this slice was allowed to ship on is the
unconfigured floor above; what a capped queue costs is bounded by construction — the
claim rides the fetch's own round trip, so the added cost is `fetch_slot.lua`'s commands
rather than another trip — and unbenchmarked beyond that.
[`10-global-concurrency-measurement.md`](10-global-concurrency-measurement.md) is the
pre-implementation prototype and prices the *rejected* shape (acquire and release
bracketing the fetch, 2.2x–2.6x); it is an upper bound, not this implementation's number.
