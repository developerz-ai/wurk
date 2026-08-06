# 00 — Semantics sign-off: the three behavior changes slice 02 is allowed to make

> Part of [`overview.md`](overview.md). Blocks [`02-fetch-ack-metrics.md`](02-fetch-ack-metrics.md).
> No code. This file is the record of what was decided, what it costs, what the
> implementation is *required* to do, and what would reverse the decision.

Slice 02 removes ~9 of the ~10 Redis commands wurk spends per job. All three of
its moves are wire-compat-safe — no Redis key, no JSON field, no score format
changes — and all three are **behavior-visible**. Wire compat is not the bar;
"a user or an operator can observe the difference" is. Each one is written up
below so the trade is on the record before it is made, per `CLAUDE.md`
("Parity tests are oracles… unless the divergence is explicitly documented as
intentional") and the overview's "Risks / open questions".

## Sign-off state

| # | Decision | Cost accepted | State |
|---|---|---|---|
| 1 | Paused-set cache, 2s TTL (P1b) | Cross-process pause visibility bounded at `PAUSED_TTL` instead of the next fetch | **Accepted** |
| 2 | `Metrics::History` in-process aggregation, ≤5s flush (P2b) | Dashboard counters lag ≤ flush interval; a hard kill drops the unflushed window | **Accepted** |
| 3 | Deferred ack piggybacked on the next fetch | Redelivery window widens from "post-job" to "next fetch / flush point" | **Accepted** |

**Provenance.** All three were raised by the plan owner in
[`overview.md`](overview.md) → "Risks / open questions", each with an explicit
recommendation (1: "P1b first, P1a if still short"; 2: "do it — it's 6 of the
~10 commands/job"; 3: "same guarantee class; must be documented as intentional
divergence for parity"). This file is the acceptance of those recommendations
plus the conditions each one is accepted *under* — the "Required to hold"
lists below are not commentary, they are the terms. An implementation that
skips one of them has not implemented the decision that was signed off.

Nothing here is gated behind a flag, a tier, or an env var — that would violate
pillar 2. The behavior described is the behavior every wurk install gets.

---

## Decision 1 — Paused-set cache with a 2s TTL

**Today.** `Fetcher::Reliable#queues_cmd` (`lib/wurk/fetcher/reliable.rb:151`)
calls `#paused_names` (`:196`) on every fetch pass — one `SMEMBERS paused` plus
a `Set` allocation. On a busy queue that is one full round trip *per job*, for a
set that is empty in the overwhelmingly common case.

**Change.** Cache the `Set` per fetcher behind a monotonic-clock TTL,
`PAUSED_TTL = 2` seconds, a constant.

**What an operator observes.** A `pause!` issued from one process (typically the
dashboard) can take up to `PAUSED_TTL` to stop fetches in a *different* process,
instead of taking effect on that process's next fetch pass.

**Why it is cheap in practice — the fleet's worst case does not move.** An idle
worker is parked in `BLMOVE` for `fetch_poll_interval` (default 2s,
`Reliable::TIMEOUT`) and cannot notice a pause until that block returns; a
2s-stale cache is exactly that same 2s. So on the default configuration the
fleet-wide worst-case pause latency is unchanged — the cache only makes the
*busy* path behave like the already-shipping *idle* path. Anyone who raises
`fetch_poll_interval` makes the poll interval dominate and the cache invisible.
In-flight jobs on a paused queue have always continued to completion
(`docs/reliability.md`, Pro §6), so the sub-second tail the cache adds is far
inside the tail an in-flight job already contributes.

**Spec position.** `docs/target/sidekiq-pro.md` §6 states the fetcher "skips any
queue listed in `paused`" and that in-flight jobs continue. It specifies no
propagation latency, and Pro cannot offer a better one — pause is a Redis SET
read by pollers, not a signal. Recorded in
[`docs/idea/parity-divergences.md`](../../../../../idea/parity-divergences.md)
anyway, because a window where a paused queue is still fetched is observable.

**Required to hold:**

- `PAUSED_TTL` is a constant, not a config knob. No new option; no flag.
- The clock is `Process.clock_gettime(CLOCK_MONOTONIC)`. Wall-clock would let an
  NTP step pin the cache open.
- A pause or unpause issued **in the fetching process itself** is visible to that
  process's fetchers on the next fetch pass, not up to `PAUSED_TTL` later. A host
  app that pauses a queue from inside a job must see its own workers stop.
- The cache is per fetcher instance and dies with it, so it cannot survive a fork.
- An empty paused set caches like any other value — the fast path is "no
  `SMEMBERS`", not "no `SMEMBERS` only when something is paused".
- `Wurk::Queue#paused?` (`lib/wurk/queue.rb:54`) keeps reading Redis directly.
  The API and the dashboard must never report from the fetch cache.

**Reversal trigger.** Any report of a pause not taking hold, or a queue that
keeps draining after the dashboard shows it paused. Reverting is deleting the
cache — one method, no data migration.

**Escalation note.** If a later re-measure shows the fetch round trip still
dominating, the overview's P1a (fold the paused check and the `LMOVE` walk into
one `EVALSHA`) is the next step. It needs its **own** sign-off: it changes the
fetch from a client-driven walk to a server-side script, which is a different
failure profile, not a wider version of this one.

---

## Decision 2 — `Metrics::History` in-process aggregation, flushed on a timer

**Today.** `Metrics::History.record` (`lib/wurk/metrics/history.rb:73`) pipelines
6 commands per job — `HINCRBY`/`HINCRBY`/`EXPIRE` against the per-minute bucket
and the same three against the per-class hourly bucket (`:86-101`). That is 6 of
the ~10 commands wurk spends per job, for counters that back a dashboard chart.

**Change.** Accumulate `{[class, minute bucket] => {p:, f:, ms:}}` in a
mutex-guarded in-process hash and flush every ≤5 seconds in one pipeline, using
the same `HINCRBY`/`EXPIRE` commands against the same keys and fields. `HINCRBY`
is additive, so N accumulated executions flush to byte-identical Redis state as N
individual writes.

**What an operator observes.**

1. The dashboard's per-minute and per-class counters lag by up to the flush
   interval. A job that ran at `T` shows up at `T + ≤5s`.
2. A **hard** process death — `SIGKILL`, OOM kill, box loss — drops the
   unflushed window: up to 5 seconds of counters for that process are never
   written. Nothing about the *jobs* is lost; the jobs ran, and their retry,
   dead-set, and ack state is Redis-resident as always. What is lost is a few
   seconds of statistics.

**Why it is acceptable.**

- **These counters were already best-effort.** `History#call`'s `ensure` block
  (`:59-63`) swallows any Redis failure into the error handler specifically so a
  metrics write can never change a job's outcome. Code that treated them as
  authoritative was already wrong; this widens a gap that was documented open.
- **It is the trade stock Sidekiq already makes.** Sidekiq flushes its process
  stats on the 10-second heartbeat and pays *zero* Redis commands per job for
  them. `docs/benchmarks.md:99` already names this batching as the fix for the
  gap and names the crash-drop as its cost. Wurk at ≤5s is *tighter* than the
  upstream cadence it is being compared against.
- **Bucket attribution survives.** The minute bucket is computed at record time
  and is part of the accumulator key, so a job that ran at 12:03:59 and flushed
  at 12:04:02 still lands in the 12:03 bucket. The divergence is visibility lag,
  never misattribution — which is what would actually corrupt a chart.
- **Graceful exits lose nothing.** The drain path flushes.

**Spec position.** `docs/target/sidekiq-free.md` §1.6 specifies the bucket keys,
fields, and TTLs — all unchanged. It does not specify write cadence, and upstream
does not write per job either. **Not** a parity divergence; documented in
`docs/metrics.md` as an operational property.

**Required to hold:**

- Keys, fields, and the `MID_TERM` TTL are untouched. The flush emits the same
  commands `pipeline_write` emits today.
- The accumulator is keyed by the bucket computed **at record time**.
- Flush on `stop`, in an `ensure`, so a graceful drain loses nothing.
- The flush is best-effort on the same terms as today: a Redis failure goes to
  the error handler and never propagates into a job. It must not silently drop
  the accumulated window on a *transient* failure — the natural shape is to
  re-merge the unflushed counts and retry on the next tick.
- The interval is ≤5s. It exists to bound the lag, not to be tuned; if it ever
  needs to be tunable it reuses the existing `config[:metrics_rollup_interval]`
  naming rather than inventing a knob.
- A test asserts flushed state is byte-identical to per-job writes, against real
  Redis (never a mock — `CLAUDE.md`).

**Reversal trigger.** Any evidence that dashboard counters are wrong rather than
late — a sum that does not reconcile against `Wurk::Stats`, or a bucket
attributed to the wrong minute. Lag is the accepted cost; incorrectness is not.

---

## Decision 3 — Deferred ack, piggybacked on the next fetch

**Today.** `UnitOfWork#acknowledge` (`lib/wurk/fetcher/reliable.rb:56`) spends a
round trip of its own the moment the Processor finishes with a job: `LREM
<private list> 1 <job JSON>`, with the poison-pill counter `DEL` already riding
along in the same pipeline. On a busy queue that is a full round trip per job
whose only purpose is bookkeeping.

**Change.** Hold the completed job's `LREM` in the fetcher and send it in the
**next** fetch's pipeline, alongside the non-blocking `LMOVE`. Steady state on a
busy queue: one round trip per job, total.

**What changes about the guarantee — precisely.**

Wurk is at-least-once and stays at-least-once. A job is never lost, because the
payload never leaves the private list any earlier than it does today — it leaves
*later*, if anything. What widens is the window in which a hard process death
causes a **completed** job to be reclaimed and run a second time: today that
window is "between the last line of `perform` and the `LREM` a few microseconds
later"; after the change it is "between the last line of `perform` and the next
fetch, or the flush points below, whichever comes first".

That is the same failure mode `docs/reliability.md` already documents under
"Duplicate execution — be honest about this", with a wider mouth. It is not a new
class of failure, and it is not reachable by a graceful exit — only by `SIGKILL`,
OOM, or hardware loss.

**Why it is acceptable.** The window it widens is already the window the
at-least-once contract exists to cover, and the mitigation is unchanged and
already mandatory: idempotent jobs. Meanwhile it is the single largest remaining
per-job round trip on the success path — the one command wurk sends that Sidekiq
sends zero of. Buying it back means either this, or accepting that the ack is a
permanent 1 RTT/job tax that no amount of downstream optimization can remove.

**Spec position.** `docs/target/sidekiq-pro.md` §3.2: "Job remains in the private
queue until the worker explicitly `LREM`s it after success or retry handling."
Wurk still `LREM`s after success or retry handling, and still only after — the
`LREM` is issued later in wall-clock terms, not earlier in the ordering. Recorded
in [`docs/idea/parity-divergences.md`](../../../../../idea/parity-divergences.md).

**Required to hold — these are correctness conditions, not preferences:**

- **Flush before `bulk_requeue`.** `Manager#hard_shutdown` (`lib/wurk/manager.rb:144`)
  calls `Fetcher#bulk_requeue` on the in-flight units. A *completed* job whose ack
  is still pending would pass the `reliable_requeue` Lua's `LREM` guard, get
  `RPUSH`ed back to the public queue, and run twice — on **every** graceful
  shutdown, not just on a kill. Pending acks flush first, unconditionally.
- **Flush before blocking.** `retrieve_work` (`:105`) must flush pending acks
  before it parks in `BLMOVE`; a blocking call cannot join a pipeline, and parking
  for `fetch_poll_interval` with an ack pending is the widened window for no gain.
- **Flush on the `queues.empty?` early return** (`:113-118`, every queue paused or
  none configured) and on **`terminate`** (`:163`). `terminate` is the trap: quiet
  is one-way, `retrieve_work` short-circuits forever after it, so an unflushed ack
  at that point would sit until shutdown.
- **Flush on processor stop/terminate**, in an `ensure`.
- **Exactly one `LREM` per job.** Deferring must not let a job be `LREM`'d twice
  or dropped from the pending set without being sent. Pin it with a command count,
  not an eyeball — `test/support/command_spy.rb` exists for this.
- **Pending acks are per fetcher, per process, never shared across a fork.**
- The poison-pill counter `DEL` keeps riding the same pipeline as its `LREM`
  (`lib/wurk/middleware/poison_pill.rb:25`), so the counter is still retired by the
  ack and not by a round trip of its own.

**Second-order effect, accepted.** A job that finishes and is then `SIGKILL`ed
before its ack flushes gets reclaimed by the reaper, which increments
`super_fetch:recovered:<jid>`. `docs/reliability.md`'s rule — "anything that
finishes an attempt counts", i.e. a finished attempt should not accrue a recovery
— now has a slightly wider window where a finished-but-unacked attempt does
accrue one. Reaching the `RECOVERY_THRESHOLD` of 3 requires three hard kills
landing inside that window for the same `jid` within 72h, and each of those
reclaims is a duplicate execution in its own right. Same failure mode, same
mitigation; no new class.

**Reversal trigger.** Any duplicate execution on a *graceful* path — that would
mean a flush point was missed, not that the trade was wrong. `bulk_requeue` and
the drain path are the two to watch.

---

## Verification these decisions are signed off *against*

Slice 02 is not done until, beyond its own "Done when":

- `test/integration/reaper_kill9_test.rb` is green — it exercises exactly the
  window decision 3 widens.
- `test/integration/graceful_shutdown_test.rb` is green, with a case that a job
  completed immediately before `SIGTERM` is **not** requeued.
- A test proves cross-process pause takes hold within `PAUSED_TTL`, and that an
  in-process pause takes hold on the next fetch pass.
- A test proves the `Metrics::History` accumulator flushes to byte-identical
  Redis state, and flushes on stop.
- `bin/rake test:parity` is green. Any parity test that fails is wurk being
  wrong, not the oracle — none of these three decisions is licence to edit one.
- `docs/reliability.md`, `docs/metrics.md`, `docs/api.md`, and
  `docs/idea/parity-divergences.md` describe the shipped behavior. They were
  written ahead of the code in this branch; if the implementation lands
  different constants or different flush points, the docs are wrong and get
  fixed in the same commit.
