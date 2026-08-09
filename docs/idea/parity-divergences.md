# Parity Divergences

Wurk targets 100% wire/behavioral compatibility with Sidekiq + Pro + Ent
(`docs/target/sidekiq-{free,pro,ent}.md`). Parity tests are oracles — any
divergence from them is a bug unless recorded here as intentional.

Each entry: what Wurk does, what the spec says, why the divergence is safe
and deliberate, and the anchor to revisit if the spec or upstream changes.
An entry tagged *decided — pending implementation* is a signed-off target the
code has not reached yet; its **Wurk:** paragraph states today's behavior.

## Reliable fetch is the only mode; no BRPOP

**Wurk:** `Wurk::Fetcher::Reliable` (BLMOVE-based, private-list-per-process)
is the sole and default fetcher. `Sidekiq::BasicFetch` is aliased straight to
it (`lib/wurk/compat.rb:104`).

**Spec:** Free Sidekiq's default `BasicFetch` uses plain `BRPOP` — a job
popped off the queue and lost mid-execution (crash, `SIGKILL`) is gone.
Reliable fetch (Pro's `super_fetch`) is opt-in there.

**Why:** at-least-once delivery only holds if in-flight jobs survive a
process crash. Wurk makes that the only behavior — a job lives in a
per-process private list until acked, and orphaned private lists are
reclaimed on next boot (`fetcher/reaper.rb`) or by the swarm. Losing jobs on
`SIGKILL` is strictly worse than Wurk's model, and nothing in the free spec
depends on BasicFetch's at-most-once gap, so there is no compat reason to
offer a lossy mode. Third-party gems that special-case `Sidekiq::BasicFetch`
by class identity still work since the alias resolves to a real class.

**Anchor:** `lib/wurk/compat.rb:104`, `lib/wurk/fetcher/reliable.rb`.

## Limiter reschedule cap routes to the dead set, not re-raise

**Wurk:** `Limiter::ServerMiddleware` reschedules an over-limit job up to
`reschedule` times (default 20); once the cap is hit, the job goes straight
to the dead set tagged `rate_limited` instead of re-raising into the normal
retry pipeline (`lib/wurk/limiter/server_middleware.rb:13-17,44`).

**Spec:** Ent §1.4 says a job that exhausts its rate-limit reschedule budget
re-raises the original error and falls through to the standard
retry/exhaustion path.

**Why (decision #16):** re-raising sends a job that is *not failing on its
own merits* — it's saturating a shared limiter — through another 25×
exponential-backoff retry cycle, further starving the limiter and every
other job behind it. Wurk treats cap-exhaustion as a distinct terminal state
("poison brake"): bounded at exactly `reschedule` attempts, visible in the
dead set with its own reason and death handlers, and it bumps
`jobs.rate_limited` instead of `jobs.retry`/`jobs.dead` misleadingly. This is
observably different (dead-set reason, handler firing) but never loses a job
and never causes a queue pileup the spec's re-raise path would risk.

**Anchor:** `lib/wurk/limiter/server_middleware.rb:13-17,44`.

## Orphan reclaim uses `LMOVE private public RIGHT RIGHT`, not `RPOPLPUSH`

**Wurk:** `Fetcher::Reaper#drain` moves each job with
`LMOVE private_list public_q RIGHT RIGHT` (`lib/wurk/fetcher/reaper.rb:272`).

**Spec:** Pro §3.2 documents `RPOPLPUSH private_list public_q` for orphan
private-list reclamation.

**Why:** `RPOPLPUSH` is a deprecated alias for `LMOVE source dest RIGHT
LEFT`/`RIGHT RIGHT` depending on read direction; Redis itself recommends
`LMOVE` for all new code (`RPOPLPUSH` stays only for backward compat).
`LMOVE ... RIGHT RIGHT` reproduces the exact same source-pop/dest-push
semantics and ordering as `RPOPLPUSH`, so wire behavior (list membership,
element order, atomicity) is unchanged — it's a syntax substitution, not a
behavior change. No parity test asserts the literal command name.

**Anchor:** `lib/wurk/fetcher/reaper.rb:272`, Pro §3.2.

## `bulk_requeue` atomically moves private → public; Pro retains in private

**Wurk:** `Fetcher::Reliable#bulk_requeue` (landed in PR2, shutdown/requeue
safety fix) does an atomic per-job `LREM private 1 job` +
`RPUSH public_q job`, conditioned so the job lands in exactly one list — see
`lib/wurk/fetcher/reliable.rb` `requeue_pipelined`.

**Spec:** Pro's `super_fetch` leaves in-flight jobs in the private list on
shutdown and relies solely on next-boot orphan reclamation
(`fetcher/reaper.rb`) to requeue them.

**Why:** leaving jobs parked in the private list until the *next* boot means
a job interrupted by a graceful-but-timed-out shutdown sits unprocessed
until the process restarts — worse latency, and if the process never comes
back (scaled down, box replaced) the reaper on a *different* process has to
find and adopt an orphaned list before the job runs at all. Requeuing
immediately and atomically at shutdown closes that gap without weakening
delivery guarantees: the LREM/RPUSH pair is only executed at process exit
for jobs that are provably still in the private list (not yet acked), so a
job is never counted twice and never silently dropped if the process dies
mid-move (worst case it's still in the private list, caught by orphan
reclaim as before, wire-identical to the previous fallback path).

**Anchor:** `lib/wurk/fetcher/reliable.rb` (`bulk_requeue`,
`requeue_pipelined`), PR2 (`fix/shutdown-requeue`), Pro §3.2 (super_fetch
shutdown behavior).

## Rolling restart drives itself from the supervise loop; no einhorn

**Wurk:** `SIGUSR1` on the swarm parent enqueues every live child into
`Swarm#rolling_restart`, a state machine (`spawn_replacement → await
heartbeat → SIGTERM old slot → await exit → next`) driven entirely by the
existing non-blocking supervise loop (`lib/wurk/swarm.rb:104-108` and the
`:usr1` case at the bottom of the signal dispatch).

**Spec:** Ent §8 describes rolling restarts via integration with
[einhorn](https://github.com/asford/einhorn) (or a similar external process
manager) that owns worker-slot bookkeeping and hands USR1 to Sidekiq as a
socket-inheritance protocol.

**Why:** Wurk's swarm parent *is* the process manager — there is no
external supervisor to hand sockets to, and the whole point of the Swarm
layer (per CLAUDE.md: "Parent process; forks N children, PID supervision,
rolling restart") is that this responsibility lives in-process. Reimplementing
einhorn's socket-handoff protocol would add a dependency and an IPC surface
with no compatibility benefit, since nothing in the free/Pro spec surface
(job execution, Redis keys, `Sidekiq::ProcessSet`) depends on *how* the
rolling restart is orchestrated — only that it achieves zero-downtime
cycling, which the in-process state machine does (verified by
`test/integration/rolling_restart_test.rb` and
`test/integration/swarm_supervision_test.rb`, PR3).

**Anchor:** `lib/wurk/swarm.rb:104-108`, PR3 (`fix/swarm-supervision`), Ent
§8.

## Reaper liveness has a residual local pid-reuse blind spot — shared with `super_fetch`, not fixed

**Wurk:** `Fetcher::Reaper#owner_alive?` fast-paths same-boot-generation
private lists (host **and** `Component::PROCESS_NONCE` match) straight to
`Process.kill(0, pid)` (`lib/wurk/fetcher/reaper.rb:270-284`). The nonce is
minted once per process image and inherited unchanged across `fork`
(`lib/wurk/component.rb:19-21`), so this group is every process forked from
the current swarm boot, not a single pid. If the OS hands a *replacement*
child, forked from that same boot, the exact pid a just-reaped sibling held,
`kill(0)` reads the new occupant as the old one — alive. Every other owner
(different nonce, pre-nonce key, or different host) is checked against the
namespace-blind heartbeat instead, which doesn't have this gap.

**Spec:** Pro §3.2's `super_fetch` decides local liveness the same way —
`Process.kill(0, pid)` against the owning pid, with no generation counter to
distinguish a reused pid from its original holder. The spec neither claims
nor tests a stronger guarantee here.

**Why:** closing this would require tracking pid *generation* — something
the OS doesn't expose (Linux pid reuse is opaque past `/proc` disappearing;
there is no monotonic "this is generation N of pid 4711" primitive to key
against). Doing it via Redis bookkeeping (e.g. a per-pid generation counter
written at fork time) would add a write on every child spawn to close a gap
that, per the swarm's own respawn ordering, doesn't arise in practice: a
replacement child is forked and reaches its own boot heartbeat before its
predecessor's pid becomes eligible for OS reuse, so the collision window is
theoretical, not observed. Since Sidekiq Pro's `super_fetch` — the spec this
component is bug-compatible with — carries the identical limitation, this is
recorded as a deliberate, matched-parity gap rather than an intentional
"improvement" left undone.

**Anchor:** `lib/wurk/fetcher/reaper.rb:270-284`, `lib/wurk/component.rb:19-21`,
`docs/reliability.md` (Reliable fetch → How "dead" is decided), Pro §3.2.

## Poison-pill counter resets on ACK, and a poison kill fires death handlers

**Wurk:** the recovery counter at `super_fetch:recovered:<jid>` is deleted the
moment the job acks — `Fetcher::Reliable::UnitOfWork#acknowledge` pipelines the
`DEL` next to its `LREM`, so an attempt that finished (returned, or raised and
booked a retry) resets the count. Only reclaims of an attempt that never acked
accumulate toward `RECOVERY_THRESHOLD`. When the threshold is crossed, the
kill goes through the death-handler chain (`notify_failure` left at its
default `true`) with a `Wurk::Middleware::PoisonPill::Poisoned` exception.

**Spec:** Pro §12 pins only the mechanism — key name, 72h TTL, threshold 3. It
says nothing about when the counter is cleared, and nothing about whether a
poison kill is a "death" for the purposes of `:death` callbacks or
`death_handlers`.

**Why:** both gaps lose work if answered the other way.

*The reset:* jids come back — a UI or API retry re-pushes the same one, and so
does any client that supplies its own. A counter that only decays on its 72h
TTL therefore accumulates across *different* runs of the same jid, so three
unrelated worker crashes (a deploy `SIGKILL`, an OOM kill, a node eviction)
inside one window dead-set a job that completed every single time it ran. The
ACK is the sharpest available "this job does not take its worker down" signal,
and the `DEL` rides the ACK's own pipeline — so the correctness costs no extra
round trip for the jobs, effectively all of them, that were never reclaimed. It
is still a Redis command; `bench:command_count` counts it as one of the three.

*The notification:* `Batch::DeathHandler` is registered as a death handler.
Suppressing the notification (Wurk's original `notify_failure: false`) meant a
poison-killed job never decremented its batch's pending count: `:death` never
fired, `:complete` never fired, and the batch hung forever with no error
anywhere. Every other terminal path in Wurk — retry exhaustion, `:discard`,
the limiter's reschedule cap — notifies, and a poison kill is the same kind of
event: the job is dead and is not coming back.

**Anchor:** `lib/wurk/middleware/poison_pill.rb` (`clear_in`, `mark_poison`),
`lib/wurk/fetcher/reliable.rb` (`UnitOfWork#acknowledge`),
`lib/wurk/processor.rb` (`process`), Pro §12.

## The ACK is deferred onto the next fetch, not sent when the job finishes

**Wurk:** when a Processor finishes with a unit of work, the `LREM
<private list> 1 <job JSON>` that retires it is held in the fetcher and sent in
the **next** fetch's pipeline, next to the `LMOVE`. The poison-pill counter
`DEL` still rides alongside it. Any pending ACK is flushed — as its own round
trip — before the fetcher blocks in `BLMOVE`, before the all-paused/no-queues
early return, on `terminate` (quiet), on processor stop, and before
`bulk_requeue` at shutdown. Steady state on a busy queue is one round trip per
job, total; an idle or draining process holds nothing.

**Spec:** Pro §3.2 — "Job remains in the private queue until the worker
explicitly `LREM`s it after success or retry handling."

**Why:** the ordering the spec pins is unchanged — the `LREM` still happens
after success or retry handling, and never before. What changes is *when* in
wall-clock terms, and the only observable consequence is the width of the
window in which a hard process death (`SIGKILL`, OOM, box loss) causes an
already-completed job to be reclaimed and run a second time. That window goes
from "the microseconds between `perform` returning and its own round trip" to
"until the next fetch, or one of the flush points above". It is the same
duplicate-execution mode `docs/reliability.md` already documents under the
at-least-once contract, with the same mitigation (idempotent jobs) — not a new
class, and unreachable on any graceful path. Nothing is ever lost: the payload
leaves the private list *later* than before, never earlier, so every death in
the widened window is a reclaim, never a drop.

The reason to take it: the standalone ACK was the largest remaining per-job
round trip on the success path, and the one command wurk sent that free
Sidekiq's `BRPOP` sends none of. Leaving it standalone means a permanent
1 RTT/job tax no downstream optimization can remove. Decision recorded with its
full terms in
`docs/plans/2026/08/06/101-faster-than-sidekiq/00-semantics-signoff.md`.

**Anchor:** `lib/wurk/fetcher/reliable.rb` (`UnitOfWork#acknowledge`,
`retrieve_work`, `bulk_requeue`, `terminate`), `lib/wurk/manager.rb`
(`hard_shutdown`), Pro §3.2.

## Paused queues are read from a 2s-TTL cache, not on every fetch pass

**Wurk:** `Fetcher::Reliable` caches the `paused` SET per fetcher behind a
monotonic-clock TTL (`PAUSED_TTL`, **2 seconds**) instead of issuing `SMEMBERS
paused` on every fetch pass. A pause or unpause issued inside the fetching
process invalidates that process's cache immediately, so a host app that pauses
a queue from within a job sees its own workers stop on the next pass.
`Wurk::Queue#paused?`, the JSON API, and the dashboard keep reading Redis
directly — the cache is fetch-path only and is never a reporting source.

**Spec:** Pro §6 — the fetcher "skips any queue listed in `paused`"; existing
in-flight jobs continue.

**Why:** the spec pins no propagation latency, and Pro cannot offer a tighter
one — pause is a SET that pollers read, not a signal that gets delivered. More
to the point, the fleet's worst-case pause latency does not move: an idle
worker is parked in `BLMOVE` for `fetch_poll_interval` (default 2s) and cannot
observe a pause until that block returns, so a 2s-stale cache is exactly the
delay the idle path already had. The cache only makes the busy path behave like
the idle one, and raising `fetch_poll_interval` makes the poll interval
dominate and the cache invisible. In exchange, a queue that is not paused —
effectively all of them, effectively always — stops costing a round trip per
job to confirm it.

**Anchor:** `lib/wurk/fetcher/reliable.rb` (`queues_cmd`, `paused_keys`),
`lib/wurk/queue.rb` (`pause!`, `unpause!`, `paused?`), Pro §6,
`docs/plans/2026/08/06/101-faster-than-sidekiq/00-semantics-signoff.md`.

## An interrupted `IterableJob` run books `p` + `ms`, never `f` (#394, resolved in PR1)

**Wurk:** an interrupted run books `<klass>|p` and `<klass>|ms`
(`jobs.success` plus the `jobs.perform`/`jobs.perform_dist` gauges), never
`<klass>|f` / `jobs.failure`. Both `Metrics::History#call` and `Metrics::Statsd#call`
now rescue `Wurk::Job::Interrupted` and re-raise it unmodified, so the exception
propagates up through them to `InterruptHandler` without flipping `success` to
false. A resumed run that later completes books a second `p`/`ms` on top of the first.

**Spec:** `docs/target/sidekiq-free.md` does not pin the interrupted case (no
divergence to measure against it). The applicable oracle is upstream
`Sidekiq::Metrics::ExecutionTracker#track` (`lib/sidekiq/metrics/tracking.rb`),
whose `rescue JobRetry::Skip` arm — the exact analog of Wurk's
`Wurk::Job::Interrupted` — calls `track_time` (books `ms`) and always reaches
the outer `ensure` (books `p`), never the `rescue Exception` arm that books
`f`.

**Why:** the divergence from that oracle has been closed. One logical job
execution spanning an interruption produces two `p` increments and two summed
`ms` windows, since the resumed run re-enters the middleware chain and books
again. That is intentional, matches upstream's own double-counting of a second
`track` call, and is not to be "fixed" back toward single-counting. Full terms
in `docs/plans/2026/08/07/101-beyond-sidekiq/00-semantics-signoff.md` §1.
Implementation: `lib/wurk/metrics/history.rb:68-73` and
`lib/wurk/metrics/statsd.rb:148-153` both rescue and re-raise `Job::Interrupted`.
Chain order verified in `test/unit/metrics_agreement_test.rb:79-82`.

**Anchor:** `lib/wurk/metrics/history.rb:65-86`,
`lib/wurk/metrics/statsd.rb:145-169,191-196`,
`lib/wurk/middleware/interrupt_handler.rb:29-34,46`,
`docs/plans/2026/08/07/101-beyond-sidekiq/00-semantics-signoff.md` §1.

## OpenTelemetry adds `traceparent`/`tracestate` as top-level job-JSON keys, opt-in only

**Wurk:** when a host opts into tracing (`config.telemetry = true`, gem
present), `Wurk::Telemetry::ClientMiddleware` writes a W3C `traceparent`
string — and `tracestate` only when the trace carries vendor state — as extra
top-level keys on the job hash, on every plain push and every `push_bulk`
item (`lib/wurk/telemetry/client_middleware.rb:26-56`). Nothing else about
the payload changes: byte-compared against an untraced push, the only key
diff is `traceparent` (`test/unit/telemetry_client_middleware_test.rb`,
`test_opting_in_adds_the_trace_context_and_nothing_else`). A host that never
opts in, or that has `telemetry = true` but no `opentelemetry-api` installed,
gets byte-identical payloads to today — proven by the same suite and by
`rake bench` with tracing off.

**Spec:** `docs/target/sidekiq-free.md` has no `traceparent`/`tracestate`
concept — Sidekiq itself ships no first-party tracing, so there is no spec
position to diverge from. The relevant question is whether an unrecognized
top-level key is safe cargo on the wire, which is a `Sidekiq::Processor`
question, not a spec one.

**Why:** `Sidekiq::Processor#dispatch` and `Sidekiq::JobLogger#prepare`,
pinned at `test/parity/.sidekiq_sha`
(`e1f808a08645f9b8a194852a171b5667f5f877bd`, fetched verbatim, not from
memory) read the job hash exclusively by known key name —
`job_hash["class"]`, `job_hash["jid"]`, `job_hash["wrapped"] ||
job_hash["class"]`, `job_hash[attr] if job_hash.has_key?(attr)` for
`logged_job_attributes` — off a plain `Sidekiq.load_json` (`JSON.parse`).
Nothing enumerates or validates the full key set, so `traceparent` is inert
cargo to a real stock-Sidekiq dispatch, not a protocol violation. This
reproduces that exact fragment against a real traced Wurk payload
(`test/unit/telemetry_client_middleware_test.rb`,
`test_a_traced_job_dispatches_unmodified_through_stock_sidekiqs_processor`
and neighbors) rather than merely asserting the payload shape in isolation.
The reverse direction — a stock-Sidekiq-shaped job with no `traceparent` at
all, hand-built and `LPUSH`ed the way `Sidekiq::Client` actually writes it —
still runs cleanly under a Wurk swarm with tracing on, as a root span with no
parent or link (`test/integration/telemetry_fork_test.rb`,
`test_a_stock_sidekiq_shaped_job_with_no_traceparent_is_consumed_here`).
`traceparent` is metadata, not an argument: `lib/wurk/encryption.rb`'s
encrypted-args envelope only ever touches `args.last`, so it neither
encrypts the trace context nor is perturbed by its presence
(`test/unit/encryption_test.rb`, the "telemetry interaction" section).
Retries reuse the original `traceparent` (`JobRetry#schedule_retry` re-ZADDs
the same hash, so the client chain never runs again), and a producer context
older than 60s becomes a span **link** instead of a parent edge — both
documented in `lib/wurk/telemetry/server_middleware.rb:28-53`. Full terms in
`docs/plans/2026/08/07/101-beyond-sidekiq/00-semantics-signoff.md` §2.

**Anchor:** `lib/wurk/telemetry/client_middleware.rb`,
`lib/wurk/telemetry/server_middleware.rb`,
`docs/plans/2026/08/07/101-beyond-sidekiq/00-semantics-signoff.md` §2,
`test/parity/.sidekiq_sha`.

## `Wurk::Status` adds `track` as a top-level job-JSON key, opt-in only

**Wurk:** `sidekiq_options track: true` (or a raw push carrying `"track":
true`) writes `track` as a top-level string/boolean key on the job hash
(`JobUtil::TRACK_VALUES = [true, false, nil]`, validated at both DSL doors —
worker `sidekiq_options` and ActiveJob — and at raw push,
`lib/wurk/job_util.rb`). `Wurk::Middleware::Status` reads it to decide whether
to open a `status:<jid>` HASH; a job that never opts in costs nothing extra on
push or execute. `nil`/absent and `false` are both "off" — the key is falsy
either way to `Wurk::Status.tracked?` (`lib/wurk/status.rb:43`).

**Spec:** No `Sidekiq::Status` concept in `docs/target/sidekiq-free.md` —
Sidekiq itself has no built-in progress/result tracking (the `sidekiq-status`
gem adds this as a third-party feature, under its own `sidekiq:status:<jid>`
Redis key, disjoint from Wurk's `status:<jid>`). No `Sidekiq::Status` alias is
added for the same reason `Sidekiq::Cron` isn't (#204): `sidekiq-status`
v4.0.0 reopens `Sidekiq::Status` itself and defines its own `.get`/`.delete`;
aliasing would hand it `Wurk::Status` to clobber. The two coexist by
construction (disjoint keys, no alias) rather than by an ecosystem suite,
which currently can't exercise the gem — see
[`docs/idea/14-ecosystem-compat.md`](14-ecosystem-compat.md).

**Why:** an unrecognized top-level key is inert cargo to a real
`Sidekiq::Processor#dispatch`, exactly the same reasoning as the OTel entry
above — nothing in stock Sidekiq's dispatch path enumerates or validates the
full job-hash key set, so a `track` key a stock consumer doesn't understand is
simply never read, not a protocol violation.

**Anchor:** `lib/wurk/job_util.rb` (`TRACK_VALUES`, `validate_track!`),
`lib/wurk/status.rb`, `lib/wurk/middleware/status.rb`.

## `timeout:`/`deadline:` add `timeout`, `deadline`, and `deadline_at` as top-level job-JSON keys, opt-in only

**Wurk:** `sidekiq_options timeout: <seconds>` writes `timeout` verbatim.
`sidekiq_options deadline: <seconds>` is resolved once at push into an
absolute `deadline_at` epoch-float (`JobUtil#stamp_deadline`,
`lib/wurk/job_util.rb:205-219`) — the *raw* `deadline` key is not itself kept
on the wire past normalization; what a worker or a retry/resume reads back is
`deadline_at`. Both are read only by `Wurk::Middleware::Timeout` (arms the
per-process `Wurk::Watchdog`) and `Wurk::Middleware::Expiry` (the
`deadline_at` preemption/skip path). A job that declares neither costs two
Hash lookups and a `yield` — no watchdog thread spawns.

**Spec:** No timeout/deadline concept in `docs/target/sidekiq-free.md` beyond
Pro's `expires_in:` (→ `expiry`, already an existing top-level key, unrelated
to this pair). Sidekiq itself ships no per-job wall-clock bound.

**Why:** same "unrecognized top-level key is inert cargo, not a protocol
violation" reasoning as the two entries above. `timeout`/`deadline_at` never
touch `lib/wurk/encryption.rb`'s envelope (only `args.last` is enveloped), and
retries/`IterableJob` resumes re-push the same job hash, so `deadline_at`
naturally carries the same absolute cutoff across every attempt rather than
resetting it.

**Anchor:** `lib/wurk/job_util.rb:205-219`, `lib/wurk/middleware/timeout.rb`,
`lib/wurk/middleware/expiry.rb`, `lib/wurk/job.rb` (`Job::TimedOut`,
`Job::DeadlineExceeded`).
