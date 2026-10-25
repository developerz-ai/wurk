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
it (`lib/wurk/compat.rb:106`).

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

**Anchor:** `lib/wurk/compat.rb:106`, `lib/wurk/fetcher/reliable.rb`.

## Concurrent limiter polls instead of using XREAD waiter signalling

**Wurk:** concurrent acquisition runs an atomic Lua script using Redis `TIME`
to trim expired slots, check ZSET cardinality, and add a slot with score
`now + lock_timeout` when capacity is available. On exhaustion it retries
acquisition after `sleep(min(remaining_wait_time, 0.05))`, raising `OverLimit`
when the wait budget is exhausted. `policy: :ignore` instead returns immediately
after the first failed acquisition, silently skipping the block without sleeping.
The release Lua script only `ZREM`s the slot; it sends no waiter notification.

Wurk does not create, read, write, or refresh the TTL of `lmtr-cw:{name}`
waiter streams. Concurrent `state_keys` contains only `lmtr-cs:{name}` and
`lmtr-stats:{name}`: `reset` deletes those keys, while `delete` additionally
removes metadata and list membership, not waiter streams. A stream left by
migration from Ent remains untouched, with its existing expiry (if any).
Successful acquisition refreshes only the slot and stats key TTLs.

**Spec:** Ent [§1.3](../target/sidekiq-ent.md#13-within_limit-semantics)
uses Redis stream `XREAD` waiter signalling when concurrent slots are exhausted;
[§1.7](../target/sidekiq-ent.md#17-redis-keys-observed) lists
`lmtr-cw:{name}` as the waiter stream and specifies `EXPIRE = ttl` for all keys.

**Why:** polling deliberately avoids waiter-stream coordination while retaining
atomic slot-capacity checks and the wait-timeout/ignore policies. The tradeoff
is repeated Redis acquisition attempts under contention and possible extra
wake-up delay after a slot is released. The 50ms bound is on each requested
sleep, not a guarantee of scheduling or acquisition latency. This does not
claim identical wake latency, FIFO ordering, or fairness relative to Ent.

**Anchor:** [poll interval](../../lib/wurk/limiter/concurrent.rb#L16),
[retry loop and immediate ignore](../../lib/wurk/limiter/concurrent.rb#L94-L103),
[acquire/release key scope](../../lib/wurk/limiter/concurrent.rb#L106-L114),
[atomic acquisition and TTLs](../../lib/wurk/lua/limiter_concurrent_acquire.lua#L15-L33),
[ZREM-only release](../../lib/wurk/lua/limiter_concurrent_release.lua#L7),
[concurrent lifecycle keys](../../lib/wurk/limiter/concurrent.rb#L55-L57), and
[reset/delete scope](../../lib/wurk/limiter/base.rb#L42-L53).

## Limiter reschedule cap routes to the dead set, not re-raise

**Wurk:** `Limiter::ServerMiddleware` reschedules an over-limit job up to
`reschedule` times (default 20); once the cap is hit, the job goes straight
to the dead set tagged `rate_limited` instead of re-raising into the normal
retry pipeline (`lib/wurk/limiter/server_middleware.rb:56-59,81-89`).

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

**Anchor:** `lib/wurk/limiter/server_middleware.rb:56-59,81-89`.

## Private-list names include a process-image nonce

**Wurk:** current private lists are named
`queue:<public>|<host>|<pid>|<nonce>|<index>` — five parts rather than four.
`<host>` is `ENV["DYNO"]` when set, otherwise `Socket.gethostname`.
`Component::PROCESS_NONCE` is 12 hex characters from `SecureRandom.hex(6)`,
minted once when the process image loads and inherited unchanged across
`fork`; it is not regenerated for each child. The reaper's `PrivateListKey`
parser accepts both current nonce-bearing keys and legacy nonce-free
`queue:<public>|<host>|<pid>|<index>` keys, so pre-upgrade in-flight lists
remain reclaimable across rolling upgrades.

**Spec:** [Pro §3.2](../target/sidekiq-pro.md#32-algorithm) specifies
`queue:<public>|<hostname>|<pid>|<index>` — four parts, with no nonce.

**Why:** a restarted process image or container can reuse both host and pid.
The nonce separates those incarnations, preventing an old private list from
being mistaken for a new owner's list (or vice versa). The reaper uses local
`Process.kill(0, pid)` only when both host and nonce match this boot; a
different incarnation is checked against its full heartbeat identity instead.
This is an intentional key-schema incompatibility: tooling that parses Pro's
fixed four-part private-list names must adapt to Wurk's five-part shape.
Legacy-key reclaim support does not make the current names byte-compatible
with Pro. Nor does the nonce distinguish reused pids among children of the
same boot, which inherit the same nonce: the
[residual same-boot pid-reuse blind spot](#reaper-liveness-has-a-residual-local-pid-reuse-blind-spot--shared-with-super_fetch-not-fixed)
remains unchanged.

**Anchor:** [key generation](../../lib/wurk/fetcher/reliable.rb#L76-L84),
[nonce lifetime](../../lib/wurk/component.rb#L20-L22),
[current and legacy parsing](../../lib/wurk/fetcher/private_list_key.rb#L18-L29)
and [tail shapes](../../lib/wurk/fetcher/private_list_key.rb#L59-L68),
Pro §3.2 (`docs/target/sidekiq-pro.md:253`).

## Orphan reclaim uses `LMOVE private public RIGHT RIGHT`, not `RPOPLPUSH`

**Wurk:** `Fetcher::Reaper#drain` moves each job with
`LMOVE private_list public_q RIGHT RIGHT` (`lib/wurk/fetcher/reaper.rb`,
`drain`). The job is pushed onto the public queue's **fetch end** (the head of
the line), so a recovered job runs before the jobs already waiting.

**Spec:** Pro §3.2 documents `RPOPLPUSH private_list public_q`. `RPOPLPUSH` is
`LMOVE source dest RIGHT LEFT`: it pushes onto the public queue's *enqueue*
end, so in Pro a recovered job goes to the back of the line. Pro 7.3's
`recover_orphan` script does exactly that (`lmove … 'right', 'left'`).

**Why:** a recovered job has already waited its turn once and was interrupted
by a crash, not by anything it did; sending it to the back of a deep queue
adds a second full queue-wait to its latency. Putting it at the head mirrors
how free Sidekiq treats interrupted work (`bulk_requeue` RPUSHes, §31 gotcha
11). Membership and atomicity are identical to Pro's: one atomic move per job,
never in zero or two lists. Only position differs — and, because jobs are
moved one at a time from the private list's oldest end onto the head, several
recovered jobs from one list end up in reverse fetch order relative to each
other. No documented contract pins the position; the parity oracle
(`test/parity/reliable_fetch_test.rb`) asserts only that a recovered job is
back in its public queue exactly once.

**Anchor:** `lib/wurk/fetcher/reaper.rb` (`drain`), Pro §3.2.

## `bulk_requeue` moves still-parked jobs to the queue head; Pro moves them to the tail

**Wurk:** `Fetcher::Reliable#bulk_requeue` (landed in PR2, shutdown/requeue
safety fix) does an atomic per-job `LREM private 1 job` +
`RPUSH public_q job`, conditioned so the job lands in exactly one list — see
`lib/wurk/fetcher/reliable.rb` `requeue_pipelined`. Only jobs handed in as
in-progress and still parked (not yet acked) are moved, onto the queue's
fetch end, so interrupted work runs next.

**Spec:** free Sidekiq's `BasicFetch#bulk_requeue` RPUSHes in-progress jobs
back to the head of their queue (free §15, §31 gotcha 11). Pro 7.3's
`super_fetch#bulk_requeue` ignores the in-progress argument and drains the
whole private list with `LMOVE private public RIGHT LEFT` — immediately, at
shutdown — so its requeued jobs go to the *tail* (back of the line).
(Earlier revisions of this entry said Pro leaves jobs in the private list for
next-boot reclaim; Pro 7.3's source does not.)

**Why:** Wurk exposes this fetcher as `Sidekiq::BasicFetch`, and free
Sidekiq's head-of-queue requeue is the behaviour that name promises; it also
keeps a job interrupted by a deploy from waiting behind the whole backlog a
second time. Like Pro, nothing waits for the next boot. A job is never counted
twice and never dropped if the process dies mid-move: the LREM/RPUSH pair runs
only for jobs provably still parked, and the worst case is the job staying in
the private list, where orphan reclaim picks it up.

**Anchor:** `lib/wurk/fetcher/reliable.rb` (`bulk_requeue`,
`requeue_pipelined`), PR2 (`fix/shutdown-requeue`), free §15, Pro §3.2.

## Limiter `ttl` below 24h is raised to 24h

**Wurk:** `Limiter::Base#initialize` clamps `ttl` to `MIN_TTL` (86 400s), so
no limiter key lives shorter than a day. A shorter value is accepted, not
rejected.

**Spec:** Ent §1.7 lists the `ttl` option with "Minimum: 24h". Sidekiq Ent
7.3's own `Limiter::Base#ttl` applies no floor at all.

**Why:** the floor is what the spec documents — keys that expire mid-job
orphan concurrent slots. Clamping rather than raising keeps an app that passes
a short `ttl` (legal in Sidekiq Ent) booting after the gem swap.

**Anchor:** `lib/wurk/limiter/base.rb` (`initialize`, `MIN_TTL`), Ent §1.7,
`test/parity/limiter_test.rb` (`test_no_key_lives_shorter_than_the_24h_minimum`).

## Rolling restart drives itself from the supervise loop; no einhorn

**Wurk:** `SIGUSR1` on the swarm parent enqueues every live child into
`Swarm#rolling_restart`, a state machine (`spawn_replacement → await
heartbeat → SIGTERM old slot → await exit → next`) driven entirely by the
existing non-blocking supervise loop (`lib/wurk/swarm.rb:238-240`, the
`:usr1` case at `lib/wurk/swarm.rb:454`, and the state machine in
`lib/wurk/swarm/restart.rb`).

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

**Anchor:** `lib/wurk/swarm.rb:238-240`, `lib/wurk/swarm/restart.rb`, PR3 (`fix/swarm-supervision`), Ent
§8.

## USR2 reopens logs; RSS recycling uses the rolling-restart machine

**Wurk:** `USR2` in a swarm child dispatches to `reopen_logs`, calling the
logger's `reopen` method if supported; it does not quiet, exit, or restart the
child. On a signal-enabled swarm parent, `drain_signals` reopens the parent's
own logger and relays `USR2` to every child. RSS checks instead call
`recycle_if_bloated`, which enqueues the affected pid via
`@restart.enqueue([pid])` — no `USR2` trigger.

The shared `Swarm::Restart` machine forks a replacement before sending `TERM`
to the old child. It waits for the replacement's heartbeat **or the heartbeat
timeout** (logging a warning on timeout), then `TERM`s the old child and waits
for its exit. An old child exceeding the drain deadline receives `KILL`; the
machine waits for the reaper to confirm exit before moving on. A replacement
observed dead during the heartbeat wait keeps the old child and retries with
backoff, if the old child is still alive.

For manual cycling, send `USR1` to a **signal-enabled swarm parent**
(`wurkswarm` or a swarm booted with `install_signals: true`), which queues all
live children. Never send `USR2` to a Wurk child expecting recycling. The Rails
auto-boot swarm does not install the parent signal handlers; see
[deployment: rolling restarts](../deployment.md#rolling-restarts) and
[memory-based auto-restart](../deployment.md#memory-based-auto-restart).

**Spec:** Ent [§7.5](../target/sidekiq-ent.md#75-memory-based-auto-restart)
describes RSS recycling as parent sends `USR2` → child quiets, drains, and
exits → parent forks a replacement. Ent
[§7.6](../target/sidekiq-ent.md#76-signals-parent--children) assigns `USR2`
to per-child graceful restart, whether memory-triggered or manual.

**Why:** preserving `USR2` for logrotate lets operators reopen logs without
cycling workers; signalling the parent reopens both parent and child loggers.
RSS recycling reuses the existing replacement-before-`TERM` state machine
rather than adding a second restart protocol. Its queue skips pids already
queued or in flight (including the replacement), so repeated RSS checks and
manual rolling restarts cannot double-enqueue the same work. This deliberately
changes the signal and hand-off ordering, not the purpose of RSS recycling.

**Anchor:** [ChildBoot signal table](../../lib/wurk/swarm/child_boot.rb#L29),
[child dispatch and reopen](../../lib/wurk/swarm/child_boot.rb#L223-L244),
[parent drain_signals](../../lib/wurk/swarm.rb#L447-L461),
[parent reopen](../../lib/wurk/swarm.rb#L474-L478),
[parent relay](../../lib/wurk/swarm.rb#L599-L601),
[RSS check and recycle enqueue](../../lib/wurk/swarm.rb#L569-L588),
[manual rolling_restart enqueue](../../lib/wurk/swarm.rb#L238-L240),
[Restart deduplication](../../lib/wurk/swarm/restart.rb#L48-L54),
[replacement spawn](../../lib/wurk/swarm/restart.rb#L99-L109), and
[heartbeat/TERM/drain phases](../../lib/wurk/swarm/restart.rb#L145-L170).

## Reaper liveness has a residual local pid-reuse blind spot — shared with `super_fetch`, not fixed

**Wurk:** `Fetcher::Reaper#orphaned?` fast-paths same-boot-generation
private lists (host **and** `Component::PROCESS_NONCE` match) straight to
`Process.kill(0, pid)` (`#local_pid_alive?`,
`lib/wurk/fetcher/reaper.rb:250-279`). The nonce is
minted once per process image and inherited unchanged across `fork`
(`lib/wurk/component.rb:20-22`), so this group is every process forked from
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

**Anchor:** `lib/wurk/fetcher/reaper.rb:250-279`, `lib/wurk/component.rb:20-22`,
`docs/reliability.md` (Reliable fetch → How "dead" is decided), Pro §3.2.

## Poison-pill counter resets on ACK, and a poison kill fires death handlers

**Wurk:** the recovery counter at `super_fetch:recovered:<jid>` is deleted the
moment the job acks — `Fetcher::Reliable::UnitOfWork#write_ack` pipelines the
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
`lib/wurk/fetcher/unit_of_work.rb` (`UnitOfWork#acknowledge`, `write_ack`),
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

**Anchor:** `lib/wurk/fetcher/unit_of_work.rb` (`UnitOfWork#acknowledge`),
`lib/wurk/fetcher/reliable.rb` (`retrieve_work`, `bulk_requeue`,
`terminate`), `lib/wurk/manager.rb`
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
Implementation: `lib/wurk/metrics/history.rb:62-87` and
`lib/wurk/metrics/statsd.rb:161-180` both rescue and re-raise `Job::Interrupted`.
Chain order verified in `test/unit/metrics_history_test.rb` and
`test/unit/metrics_statsd_test.rb` (the #394 real-chain tests).

**Anchor:** `lib/wurk/metrics/history.rb:62-87`,
`lib/wurk/metrics/statsd.rb:161-180`, `lib/wurk/metrics/statsd.rb:213-218`,
`lib/wurk/middleware/interrupt_handler.rb:35-37,50`,
`lib/wurk/middleware/expiry.rb:62-64,111`,
`lib/wurk.rb:335`, `lib/wurk.rb:351`, `lib/wurk.rb:358`,
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
`deadline:` is the *input option*: it too rides the wire verbatim, and push-time
normalization derives an absolute `deadline_at` epoch-float from it
(`JobUtil#stamp_deadline`, `lib/wurk/job_util.rb:237-242`). The two are not
interchangeable — `deadline` is a relative duration frozen at declaration,
`deadline_at` the absolute cutoff every later attempt measures against, so a
retry or an `IterableJob` resume reads `deadline_at` and never re-derives one
(`||=` keeps the first push's stamp). The persisted top-level fields are
therefore `timeout`, `deadline`, and `deadline_at`. `timeout` and `deadline_at`
are read only by `Wurk::Middleware::Timeout` (arms the per-capsule
`Wurk::Watchdog`) and `Wurk::Middleware::Expiry` (the `deadline_at`
preemption/skip path). A job that declares neither costs two Hash lookups and a
`yield` — no watchdog thread spawns.

**Spec:** No timeout/deadline concept in `docs/target/sidekiq-free.md` beyond
Pro's `expires_in:` (→ `expiry`, already an existing top-level key, unrelated
to this pair). Sidekiq itself ships no per-job wall-clock bound.

**Why:** same "unrecognized top-level key is inert cargo, not a protocol
violation" reasoning as the two entries above. `timeout`/`deadline_at` never
touch `lib/wurk/encryption.rb`'s envelope (only `args.last` is enveloped), and
retries/`IterableJob` resumes re-push the same job hash, so `deadline_at`
naturally carries the same absolute cutoff across every attempt rather than
resetting it.

**Anchor:** `lib/wurk/job_util.rb:237-242`, `lib/wurk/middleware/timeout.rb`,
`lib/wurk/middleware/expiry.rb`, `lib/wurk/job.rb` (`Job::TimedOut`,
`Job::DeadlineExceeded`).

## Scheduler wait falls back to one average interval, not a fixed 5s sleep

**Wurk:** when the Redis read that sizes the poll interval fails, `Scheduled::Poller#wait` reports the error (`scheduler_wait`) and waits one plain average interval on its own wake-up signal.

**Spec:** Sidekiq rescues in `wait` and sleeps a fixed 5 seconds.

**Why:** the wait stays interruptible, so `terminate` is not held up by a sleep; the thread survives either way, which is the behaviour that matters.

**Anchor:** `lib/wurk/scheduled.rb`.

## Unpromotable scheduled/retry members go to the dead set without trimming or death handlers

**Wurk:** a member the promoter cannot decode or push (reliable Lua path or default `Enq#push_promoted`) is moved to `dead` as a plain ZADD with its original bytes, scored now.

**Spec:** Sidekiq's promoter has no poison handling; one undecodable member blocks the set.

**Why:** a poison member must not starve the rest of `retry`/`schedule`. Running death handlers for a payload that never ran as a job would report a job failure that did not happen.

**Anchor:** `lib/wurk/lua.rb` (`RELIABLE_SCHEDULE_PROMOTE`), `lib/wurk/scheduled.rb`.

## Leader re-announces after stepping down on an error

**Wurk:** a Redis error during a leader campaign drops leadership and clears the token; the next successful campaign counts as a fresh win (new token, `:leader` fires again).

**Spec:** Ent's leader election keeps its claim across transient errors until the TTL lapses.

**Why:** after an error the process cannot know whether it still holds the lock; stepping down is the safe reading, and a duplicate `:leader` event is harmless where a stale "I am leader" is not.

**Anchor:** `lib/wurk/leader.rb`, `lib/wurk/lua/leader_campaign.lua`.

## Quiet does not step the leader down; full shutdown does

**Wurk:** quiet is cluster-global and one-way, signalled with `TSTP`
(`lib/wurk/swarm.rb:224-231`, `lib/wurk/api/swarm.rb:37`
`QUIET_SIGNAL = 'TSTP'`, `lib/wurk/cli.rb:66-68`). `Launcher#quiet`
(`lib/wurk/launcher.rb:115-125`) quiets every manager and the scheduled
poller, deliberately leaves the cron poller running, and never touches
`@leader` — the renewal loop keeps renewing the lock every 15s while held
(`lib/wurk/leader.rb:251-258`) straight through a quiet. Leadership ends only
on full shutdown: `Launcher#stop` → `release_components` →
`stop_periodic_components` (`lib/wurk/launcher.rb:289-294`, `@leader&.stop`)
→ `Leader#stop` (`lib/wurk/leader.rb:166-176`), which joins the campaign
thread and then CAS-releases `dear-leader`.

**Spec:** Ent §6.2 steps the leader down immediately on USR1 quiet (since
2.2.3 — invalid leaders self-evict); a follower re-campaigns, so §2.6
periodic keeps enqueuing.

**Why:** Wurk never quiets with USR1 — USR1 is the swarm parent's rolling
restart — so the Ent trigger does not exist here; Wurk's quiet signal is
`TSTP` (free spec §21.3). Quiet pauses fetching without ending the process,
and `Launcher#quiet` deliberately keeps the cron poller (Ent §2.6: a quieted
leader still enqueues), which enqueues only under the single cluster leader —
keeping the renewal makes `leader?` stay truthful on the quieted process
instead of evicting and re-campaigning through every quiet. The failure Ent's
2.2.3 change guards is covered anyway: a leader that cannot renew steps down
on campaign loss or campaign error (`lib/wurk/leader.rb:197,281-286`). Full
shutdown releases the lock deliberately, periodic loops stopped before the
CAS release, rather than waiting out the TTL.

**Anchor:** `lib/wurk/launcher.rb:115-125` (`#quiet`),
`lib/wurk/launcher.rb:289-294` (`#stop_periodic_components`),
`lib/wurk/leader.rb:166-176` (`#stop` join + release); pinned by
`test/unit/launcher_test.rb` (`test_quiet_does_not_terminate_cron_poller`,
`test_quiet_does_not_stop_the_cluster_leader`,
`test_stop_stops_the_cluster_leader`).

## `SortedEntry#reschedule` returns nil for a removed job instead of re-creating it

**Wurk:** `reschedule` uses `ZADD XX INCR`; a member that was already promoted or deleted stays gone and the call returns nil.

**Spec:** upstream's `ZINCRBY` re-creates the member.

**Why:** resurrecting a job that already ran (or was deleted on purpose) double-runs it.

**Anchor:** `lib/wurk/sorted_entry.rb`.

## Dashboard bulk actions report per-entry failures with HTTP 422

**Wurk:** retry / add-to-queue / kill actions continue past a rejected entry, put it back in its set, and answer `422 {ok: false, count, failed: [{key, error}]}`; Redis errors still answer 503.

**Spec:** Sidekiq's Web stops at the first exception (500).

**Why:** one bad payload must not block the rest of a bulk action or lose the entry it failed on.

**Anchor:** `app/controllers/wurk/api_controller.rb`, `lib/wurk/job_set.rb`.

## Dashboard job-set HTTP request shapes differ from Sidekiq Web

**Status:** recorded compatibility gap, not an approved safe or deliberate
exception. This entry concerns request paths and parameters, independently of
the bulk-failure response behavior above; it changes no runtime behavior.

**Spec versus Wurk:** all rows below are POSTs, relative to the Web/engine
mount. Spec routes come from [free §25.4](../target/sidekiq-free.md#254-routes);
Wurk routes add `/api` and rename `morgue` to `dead`.

| Operation | Spec route and explicit detail | Wurk route and supported commands |
|---|---|---|
| Retries bulk | `/retries`: `key[]`, params `retry`/`delete`/`kill` | `/api/retries`: `retry`, `delete`, `kill` |
| Retries single | `/retries/:key`: single action; parameters unspecified | `/api/retries/:key`: `retry`, `delete`, `kill` |
| Retries all | `/retries/all/delete`, `/retries/all/retry`, `/retries/all/kill` | `/api/retries/all/:cmd`: `delete`, `retry`, `kill` |
| Scheduled bulk | `/scheduled`: `delete`/`add_to_queue`; parameter names unspecified | `/api/scheduled`: `delete`, `add_to_queue` |
| Scheduled single | `/scheduled/:key`: single; parameters unspecified | `/api/scheduled/:key`: `delete`, `add_to_queue` |
| Scheduled all | `/scheduled/all/delete`, `/scheduled/all/add_to_queue` | `/api/scheduled/all/:cmd`: `delete`, `add_to_queue` |
| Morgue/dead bulk | `/morgue`: bulk action; commands and parameters unspecified | `/api/dead`: `retry`, `delete` |
| Morgue/dead single | `/morgue/:key`: single action; commands and parameters unspecified | `/api/dead/:key`: `retry`, `delete` |
| Morgue/dead all | `/morgue/all/delete`, `/morgue/all/retry` | `/api/dead/all/:cmd`: `delete`, `retry` |

**Wurk request bodies:** the SPA sends bulk `{ "keys": [key, ...], "cmd":
command }` and single `{ "cmd": command }` as JSON with
`Content-Type: application/json`. All-set requests put the command in the path
and send no body. The controller reads `params[:cmd]` and, for bulk,
`Array(params[:keys])`; it does not translate singular `key[]` or action-named
parameters into that contract. A retries bulk request carrying only the spec's
`key[]` plus a `retry`, `delete`, or `kill` parameter therefore has no recognized
`cmd` and reaches the `400 { error: 'unknown action' }` branch, even if sent to
Wurk's `/api/retries` path. Changing the path alone is not sufficient.

**Key delimiters and evidence limits:** Wurk's shared frontend key builder uses
`"<score>|<jid>"` for all three sets and URL-encodes it for single requests.
The spec explicitly gives `"<score>-<jid>"` for the retry-detail GET row
([line 1431](../target/sidekiq-free.md#L1431)); it does not explicitly define
that delimiter for every other set or POST row. The reported upstream pattern
of `key[]` plus action-named parameters is explicit in the spec only for
retries bulk ([line 1432](../target/sidekiq-free.md#L1432)). The scheduled bulk
row lists actions, not their parameter encoding, and the morgue bulk and
single-action rows do not specify request shapes. Extending the reported
pattern to those rows is not a verified upstream fact here: no stock upstream
implementation was inspected and no compatibility test was executed for this
entry. The JSON bodies described above are verified Wurk client behavior, not
a claim that its controller accepts only JSON or that the spec requires a
particular content type.

**Anchor:** [Wurk route scope](../../config/routes.rb#L7) and
[job-set routes](../../config/routes.rb#L39-L50),
[command whitelists](../../app/controllers/wurk/api_controller.rb#L40-L45),
[single/all dispatch](../../app/controllers/wurk/api_controller.rb#L110-L148),
[bulk parameter lookup and rejection](../../app/controllers/wurk/api_controller.rb#L373-L397),
[frontend key builder](../../frontend/src/hooks/useJobSetActions.ts#L11-L16),
[single/bulk/all requests](../../frontend/src/hooks/useJobSetActions.ts#L40-L56),
[JSON encoding](../../frontend/src/http.ts#L33-L41), and
[spec retries/scheduled/morgue rows](../target/sidekiq-free.md#L1430-L1448).

## A lost-reply Idempotency-Key stays pending until its TTL

**Wurk:** the REST API releases an `Idempotency-Key` only when the error proves the write never applied; an unknown outcome (lost reply) keeps the key pending until its TTL (1h default), so a client retry gets 409 "in progress" rather than a second enqueue.

**Spec:** no upstream equivalent (Wurk REST API).

**Why:** releasing on an unknown outcome is exactly how a retry double-enqueues.

**Anchor:** `lib/wurk/api/idempotency.rb`, `lib/wurk/client.rb`.

## `reconnect_attempts: 1` is kept — same exposure as Sidekiq #3303

**Wurk:** redis-client re-sends the one in-flight command once on a dropped socket (Sidekiq's setting). `RedisPool` never replays a block whose connection was handed out.

**Spec:** identical to Sidekiq.

**Why:** with 0, every stale socket after a Redis restart or failover surfaces as an enqueue error the pool cannot safely replay. A lost reply on the re-sent pop is the residual risk upstream accepts too.

**Anchor:** `lib/wurk/redis_pool.rb`.

## `JobLogger#prepare` runs inside `retrier.global`

**Wurk:** the job logger's context setup runs inside the global retry handler.

**Spec:** §14 lists `prepare` before `retrier.global`.

**Why:** an exception from `prepare` (a logger without `with_level`, a SemanticLogger quirk) would otherwise escape with the job un-ACKed in a live process's private list, stuck until restart.

**Anchor:** `lib/wurk/processor.rb`.

## An internal exception requeues the job and keeps the processor thread

**Wurk:** a non-`Handled` exception escaping the retry layer (e.g. the retry ZADD fails on a blip) is reported as `Internal exception!`, the unit of work is requeued (LREM private + RPUSH public), and the processor thread continues.

**Spec:** the exception kills the processor thread and the job stays in the private list until the process restarts (reaped then).

**Why:** a live owner's private list is never reaped, so upstream's behaviour strands the job for the life of the process. Residual risk: a job that fails the same way every time cycles through requeue, reported each time.

**Anchor:** `lib/wurk/processor.rb`.

## `set(wait:)` / `perform_in` reject String intervals

**Wurk:** a String interval raises `ArgumentError`.

**Spec:** upstream coerces with `to_f`, so `"soon"` silently means now.

**Why:** a silent "run now" for a typo is worse than an error at enqueue.

**Anchor:** `lib/wurk/worker/setter.rb`.

## A logger without `with_level` ignores a job's `log_level`

**Wurk:** `JobLogger` checks `respond_to?(:with_level)` once; without it the job runs at the logger's level.

**Spec:** upstream calls `with_level` unconditionally and raises.

**Why:** a logging capability must not decide whether a job runs.

**Anchor:** `lib/wurk/job_logger.rb`.

## A `jobs` block holds the batch open with a sentinel member

**Wurk:** while a `Batch#jobs` block is open, a `hold:<id>` member sits in `b-<bid>-jids` and adds 1 to `pending`; it is released at block exit. If the block that created the batch raises, the hold stays and the batch never fires (nothing was enqueued). A re-entrant block that adds nothing gets no `Empty` job.

**Spec:** Pro §2.3 says the block is atomic; the mechanism is not specified.

**Why:** without a sentinel, a job that finishes before the next one is pushed lets the batch fire early, and never again.

**Anchor:** `lib/wurk/batch.rb`, `lib/wurk/lua/batch_hold.lua`.

## Child-batch success/complete callbacks count toward the parent batch

**Wurk:** a child batch's `:complete`/`:success` callback jobs are pushed into the parent batch (`bid` = parent) and count toward its `total`/`pending`/`failures`; a dead child callback suppresses the parent's `:success`. `:death` callbacks stay outside. The callback job class is `Wurk::Batch::CallbackJob`.

**Spec:** Pro §2.9 requires the parent to wait for the child's callbacks; Pro's mechanism and class name are not in the spec.

**Why:** it is the only way the §2.9 step workflow can observe step N+1 before the parent fires.

**Anchor:** `lib/wurk/batch/callbacks.rb`.

## Jobs of an invalidated batch skip `perform`

**Wurk:** the batch server middleware skips `perform` for jobs of an invalidated batch and acks them as successes.

**Spec:** Pro §2.6 implies jobs check `valid_within_batch?` themselves.

**Why:** pre-existing behaviour, kept; the outcome (no work done, batch completes) is the same.

**Anchor:** `lib/wurk/batch/server_middleware.rb`.

## Batch "fired" markers use `b-<bid>-success`/`-complete`

**Wurk:** `b-<bid>-complete`/`-success`/`-death` are `"1"` markers meaning "already fired" (complete/success written after the enqueue, death claimed before), and callback specs live in a `callbacks` field on `b-<bid>`.

**Spec:** Pro §2.8 lists `-success`/`-complete` as "callbacks pending" and `-notify`/`-cbsucc` for queued/dedup — contents unspecified.

**Why:** unverifiable without a real Pro dump (plan 101, U8 → R2). Risk: a Pro batch in flight at the swap may skip its callbacks. Revisit with a dump.

**Anchor:** `lib/wurk/batch/callbacks.rb`.

## Encrypted job hashes are re-sealed after the chain unwinds

**Wurk:** the encryption server middleware decrypts in place for `perform`, then restores the envelope in an `ensure`; middleware outside it sees ciphertext again.

**Spec:** Ent §4.1 — `perform` sees plaintext; what outer middleware sees afterwards is unspecified.

**Why:** any later re-push of the hash must never carry plaintext.

**Anchor:** `lib/wurk/encryption.rb`.

## Periodic: late slots skipped, bare-hash `args` is one argument

**Wurk:** a periodic slot more than max(90s, 1.5× tick) late is claimed, logged as missed and not enqueued; a non-Array `args:` is passed as a single argument; `Loop#queue` reports the worker's queue when the loop sets none.

**Spec:** Ent §2.6 says no backfill (threshold unspecified); Ent splats `args`.

**Why:** a hash splatted into keyword-ish positional args silently changes the call.

**Anchor:** `lib/wurk/cron.rb`.

## Throttle admission costs two round trips

**Wurk:** `TIME` is read in Ruby and the aligned slot key passed via `KEYS`.

**Spec:** none — `Wurk::Throttle` is a Wurk extra, not a Sidekiq surface (`lib/wurk/throttle.rb`): nothing in the Sidekiq key schema (sidekiq-free.md §1) lives under `throttle:` (`lib/wurk/keys.rb`), sidekiq-throttled keys off a host-supplied strategy name and cannot collide, and Ent's only rate-limiting surface (`Sidekiq::Limiter`, ent §1) is the rolling window Throttle deliberately does not duplicate — there is no `Sidekiq::Throttle` alias.

**Why:** a key built inside Lua breaks Redis Cluster and Dragonfly.

**Anchor:** `lib/wurk/throttle.rb`, `lib/wurk/lua/throttle_slot.lua`.

## Flow nodes with `at:` carry an `at` field and show `enqueued` once released

**Wurk:** flow node records gain a Wurk-only `at` field; a node released onto `schedule` reports state `enqueued`.

**Spec:** none — `Wurk::Flow` is a Wurk extra, not parity (`lib/wurk/compat.rb`): Sidekiq has no DAG, so nothing in its key schema (sidekiq-free.md §1) answers to `flow:` (`lib/wurk/keys.rb`), and node records live in Wurk-only `flow:<fid>:<index>` hashes nothing outside Wurk reads. The one spec-adjacent surface is compatibility, not divergence: a released `at:` node lands on the standard `schedule` zset as the exact member Client#push writes, so Sidekiq's own scheduled-job semantics take over.

**Why:** the `at` record field *is* the release score — `flow_advance.lua` HMGETs it and ZADDs the stored payload onto `schedule` with it at a release that can come long after creation; it is carried on the record (`creation.rb` writes it as a string and stores the payload as the schedule member) so the advance script never JSON-decodes the payload — the cjson rule — and the dashboard/API can show the fire time without decoding the schedule member. `enqueued` means out of the flow's hands: the script writes it before the `at:` branch, and a schedule-bound node's remaining wait is ordinary scheduler promotion, not flow state, while `waiting` would misreport already-satisfied dependencies as pending and stall every progress view reading state.

**Anchor:** `lib/wurk/flow/creation.rb`.

## Sidekiq Enterprise / web internals not provided

**Wurk:** `Sidekiq::Enterprise::VERSION` is undefined (Wurk advertises as OSS: `Sidekiq.pro?`/`ent?` are false), and upstream's ERB dashboard internals (`Sidekiq::Web::Action`, `Route`, `Router`, `WebHelpers`) and `Sidekiq::TestingClient` are not provided.

**Why:** the dashboard is a SolidJS SPA, and advertising Ent would make gems take Ent-only code paths that call licensed internals.

**Anchor:** `lib/wurk/compat.rb`, `test/unit/spec_constants_test.rb`.

## Old Wurk metrics keys are not read after the format restore

**Wurk:** per-class metrics written by earlier Wurk versions (`j|YYYYMMDD|…`, `<klass>-YYYYMMDD-H`) are not read; they expire within 3 days.

**Why:** no backwards-compat shims (CLAUDE.md); the restore makes Wurk read Sidekiq's own history, which is what a migration needs.

**Anchor:** `lib/wurk/metrics/history.rb`.

## Metrics/profiler details

**Wurk:** `Sidekiq::Metrics::Histogram` is a module of bucket constants and the key format, not upstream's instance API; the profiler does not store upstream's `filename` field (a deleted temp path); `ProfileSet` skips a record whose hash has expired instead of raising; `JobSet#each` / `Queue#each` offsets never go below 0.

**Anchor:** `lib/wurk/metrics/histogram.rb`, `lib/wurk/profiler.rb`, `lib/wurk/profile_set.rb`, `lib/wurk/job_set.rb`.

## Stats HTTP routes and payload parity are unsupported

**Wurk:** the engine exposes `GET /api/stats` and `GET /api/queues`, relative
 to the host application's mount (`config/routes.rb:6-10`).
`ApiController#stats` renders `Serializers.stats_payload(Wurk::Stats.new)`
(`app/controllers/wurk/api_controller.rb:60-62`): a flat object with
`processed`, `failed`, `expired`, `enqueued`, `busy`, `scheduled`, `retries`,
`dead`, `processes`, `latency`, and `queues`. Each queue summary contains
`name`, `size`, `latency`, and `paused`
(`app/controllers/wurk/api/serializers.rb:17-35`, `stats_payload` and
`queue_summary`). `GET /api/queues` returns an array of those same summaries
(`app/controllers/wurk/api_controller.rb:64-66`). Route and payload parity
with the three stats routes below are unsupported: the flat stats response
has no `sidekiq`/`redis`/`server_utc_time` envelope. HTML requests to those
paths can reach the SPA catch-all (`config/routes.rb:126-134`), which is not
the specified redirect or JSON handler.

**Spec:** free [§25.4](../target/sidekiq-free.md#254-routes) specifies
`GET /dashboard/stats` → 302 to `/stats`, `GET /stats` → JSON stats with
`sidekiq`, `redis`, and `server_utc_time`, and `GET /stats/queues` → JSON
queue sizes (`docs/target/sidekiq-free.md:1451-1453`).

**Why:** the current endpoints serve the SolidJS SPA; `stats_payload` is
shared by its landing page and SSE feed and renames canonical stats accessors
for that dashboard's wire shape
(`app/controllers/wurk/api/serializers.rb:12-16`). This explains the current
SPA-specific surface, not compatibility with Sidekiq HTTP clients: callers
expecting the spec's routes, redirect, or payload cannot use it as a drop-in
replacement. This entry records that unsupported contract without treating
the gap as proven safe or claiming the three spec rows are implemented.

**Anchor:** free §25.4; `config/routes.rb:6-10,126-134`;
`app/controllers/wurk/api_controller.rb:60-66` (`stats`, `queues`);
`app/controllers/wurk/api/serializers.rb:12-35` (`stats_payload`, `queue_summary`).

## Busy-control HTTP request-shape parity is unsupported

**Wurk:** the engine exposes `POST /api/busy/quiet` and
`POST /api/busy/stop`, relative to the host application's mount
(`config/routes.rb:7,57-58`). The action is selected by the path:
`ApiController#quiet_process` calls `signal_processes(:quiet!)` and
`#stop_process` calls `signal_processes(:stop!)`
(`app/controllers/wurk/api_controller.rb:167-168`). The helper reads only
`identity`: absent or empty, or `"all"`, targets every live non-embedded
process; a named identity targets that process. An unknown identity returns
404, and a named embedded process is not signalled and returns count 0
(`app/controllers/wurk/api_controller.rb:430-441`). It does not select the
action using `quiet` or `stop` request parameters.

**Spec:** free [§25.4](../target/sidekiq-free.md#254-routes) specifies
`POST /busy` with `identity`, `quiet`, and `stop` parameters (per-process or
all), not split action-specific paths
(`docs/target/sidekiq-free.md:1425`). That row does not define precedence
between the action parameters.

**Why:** the split endpoints serve the SPA's busy-page controls. Sharing
quiet/stop functionality and identity targeting does not establish HTTP
request compatibility: a client sending the specified `POST /busy` request
cannot treat Wurk's action-in-path endpoints as an equivalent contract.
This entry records unsupported request equivalence, not a proven-safe gap
or a compatibility handler; it does not infer unspecified flag semantics.

**Anchor:** free §25.4 (`docs/target/sidekiq-free.md:1425`);
`config/routes.rb:7,53-58`;
`app/controllers/wurk/api_controller.rb:167-168,430-441`
(`quiet_process`, `stop_process`, `signal_processes`).

## `HEAD /` does not implement the Redis health probe

**Wurk:** the dashboard root, relative to the host application's engine mount,
routes to `DashboardController#index`, which renders the SPA shell. `HEAD /`
does not implement the spec's `LLEN queue:default` Redis health probe; a
successful root response does not verify Redis connectivity.

Worker health probes are instead opt-in via `config.health_check(port:)` in a
`configure_server` block, on a separate TCP port rather than the dashboard
mount. `GET /live` reports launcher liveness (200 unless stopping, then 503),
without checking Redis. `GET /ready` requires Redis `PING`, a fresh local
heartbeat, and, in a swarm, enough children with fresh heartbeats (200 when
ready, otherwise 503). The listener rejects non-GET requests, including
`HEAD`, with 405.

**Spec:** free [§25.1](../target/sidekiq-free.md#251-entrypoint) specifies
`HEAD /` calls `LLEN queue:default`;
[§25.4](../target/sidekiq-free.md#254-routes) lists `HEAD /` as the Redis
health-check route.

**Why:** the SPA shell and the dedicated worker listener are separate surfaces.
The listener distinguishes process liveness from Redis/heartbeat readiness,
but its opt-in configuration, port, methods, paths, and Redis command differ
from the specified dashboard probe. It is not wire-equivalent to `HEAD /` and
does not make existing Sidekiq health-probe clients drop-in compatible. This
entry records the unsupported contract, not a claim that the gap is safe.

**Anchor:** free §25.1/§25.4 (`docs/target/sidekiq-free.md:1382,1422`);
[root route](../../config/routes.rb#L4);
[SPA root controller](../../app/controllers/wurk/dashboard_controller.rb#L39-L41);
[opt-in configuration](../../lib/wurk/configuration.rb#L702-L726);
[dedicated listener bind](../../lib/wurk/health.rb#L119-L123);
[GET-only dispatch](../../lib/wurk/health.rb#L258-L266);
[liveness and local readiness](../../lib/wurk/health.rb#L277-L305); and
[swarm readiness](../../lib/wurk/health.rb#L354-L367).

## Queue `?direction=asc` is unimplemented

**Wurk:** `GET /queues/:name?direction=asc` does not change queue-wide
ordering or pagination. The queue API reads `page`, `count`, and `substr`,
then slices jobs in enumeration order without reading `direction`. The SPA
requests only `page` and `count`; its column sorting rearranges the fetched
page, not the entire queue.

**Spec:** free [§25.4 Routes](../target/sidekiq-free.md#254-routes),
`GET /queues/:name` row, lists `?count=`, `?page=`, and `?direction=asc`
for queue contents.

**Why:** an operator following a link with `direction=asc` still gets normal
queue pagination, not the requested queue-wide ordering. Sorting a column on
one fetched page is not equivalent support: it does not change which jobs
belong on each page. This entry records an unsupported contract, not a claim
that the gap is safe.

**Anchor:** [free §25.4 Routes](../target/sidekiq-free.md#254-routes)
(`GET /queues/:name`, `docs/target/sidekiq-free.md:1427`);
[queue API pagination](../../app/controllers/wurk/api_controller.rb#L68-L76);
[accepted pagination parameters](../../app/controllers/wurk/api/pagination.rb#L29-L35);
[enumeration-order slicing](../../app/controllers/wurk/api/pagination.rb#L70-L95);
[SPA queue request](../../frontend/src/pages/Queues.tsx#L59-L72); and
[page-local sorting](../../frontend/src/pages/Queues.tsx#L90).

## Dashboard `?days=N` is unimplemented

**Wurk:** `GET /?days=N` does not select the requested historical horizon.
The dashboard defaults to a `1h` view and offers its own `1h`, `24h`, `7d`,
and `30d` range controls. It requests history using the selected range's
bucket and window, without reading `days`.

**Spec:** free [§25.4 Routes](../target/sidekiq-free.md#254-routes),
`GET /` dashboard row, specifies `?days=N` with `N` in `1..180`.

**Why:** bookmarks and shared dashboard links carrying `days=N` do not open
the requested horizon; operators instead see the default `1h` view and must
use Wurk's existing range controls. Those controls are not support for the
specified URL parameter or its full range. This entry records an unsupported
contract, not a claim that the gap is safe.

**Anchor:** [free §25.4 Routes](../target/sidekiq-free.md#254-routes)
(`GET /`, `docs/target/sidekiq-free.md:1423`);
[available dashboard ranges](../../frontend/src/pages/Dashboard.tsx#L60-L65);
[default range and history request](../../frontend/src/pages/Dashboard.tsx#L86-L109);
and [range controls](../../frontend/src/pages/Dashboard.tsx#L213-L219).

## Dashboard and web extension differences

**Wurk:** `GET /profiles/:key` requires same-origin, a typed URL, or a same-host Referer (Sidekiq answers any GET); extension `redirect_to` inside the SPA falls back to the extension root for off-site targets (the SPA loads extensions with `fetch`, which cannot follow cross-origin redirects); `reload_page` inside the SPA goes to the extension index; `Sidekiq::Web.views` is an accepted, ignored array; read-only mode answers TRACE with 403 on the standalone mount; the health server closes connections past 16 concurrent unanswered.

**Why:** cross-site GETs must not trigger third-party uploads; the rest follow from the SPA architecture.

**Anchor:** `app/controllers/wurk/profiles_controller.rb`, `lib/wurk/web/extension.rb`, `lib/wurk/health.rb`.

## A job whose encrypted argument cannot be decrypted goes straight to the dead set

**Wurk:** a decrypt failure (unknown key version, a key resolver that returns nil or raises, a corrupt envelope) raises `Wurk::Encryption::DecryptionError`, increments `jobs.encryption_error`, and moves the job to the dead set without retries. The envelope is kept, so the job can be retried from the dashboard once the key is restored.

**Spec:** Ent §4.6 routes a failed decrypt through the normal retry pipeline with `OpenSSL::Cipher::CipherError`.

**Why:** 25 retries over ~21 days cannot bring a missing key back, and each one re-logs the same failure; the dead set is where an operator looks, and a manual retry works the moment the key is back. Documented for users in `docs/encryption.md`.

**Anchor:** `lib/wurk/encryption.rb`, `test/parity/encryption_test.rb` (`test_forged_tag_dead_sets_as_encryption_error_without_retry` pins the dead record tagged `encryption_error` and the absent retry entry).

## Scheduled job expiry counts from the scheduled time

**Wurk:** `expires_in` on a scheduled job is measured from its scheduled run time (2h delay + 1h `expires_in` → expires 3h after enqueue).

**Spec:** Pro §7 says "the clock starts at enqueue" but its own worked example gives 3h; Wurk follows the example.

**Anchor:** `lib/wurk/job_util.rb`, `test/parity/expiring_test.rb`.
