# Parity Divergences

Wurk targets 100% wire/behavioral compatibility with Sidekiq + Pro + Ent
(`docs/target/sidekiq-{free,pro,ent}.md`). Parity tests are oracles — any
divergence from them is a bug unless recorded here as intentional.

Each entry: what Wurk does, what the spec says, why the divergence is safe
and deliberate, and the anchor to revisit if the spec or upstream changes.
An entry tagged *decided — pending implementation* is a signed-off target the
code has not reached yet; its **Wurk:** paragraph states today's behavior.

## Immediate plain multi-queue pushes register queues per group

**Wurk:** immediate plain payloads are grouped by queue, and each group gets
its own pipeline containing `SADD queues <queue>` followed by
`LPUSH queue:<queue> ...`. After a successful push, `queues` SET membership
and payload delivery are equivalent to registering all grouped queues upfront:
all destination queues are registered and their jobs are queued, with existing
SET members preserved. If a later group's pipeline fails **before its commands
are sent to Redis**, earlier acknowledged groups retain both their delivered
jobs and queue membership. A previously unregistered destination in that unsent
group has neither queued jobs nor `queues` membership from this push.

**Spec:** free
[§7.1 `atomic_push` semantics](../target/sidekiq-free.md#71-atomic_push-semantics-critical-for-wire-compat)
specifies one upfront `SADD queues <all grouped keys>` before the per-queue
`LPUSH` loop, rather than Wurk's per-group registration. Once that upfront
`SADD` executes, even a later queue whose `LPUSH` is never sent is registered.

**Why:** per-group pipelines let Wurk mark each group delivered as soon as its
reply arrives, keeping acknowledged jobs out of the reliable-push replay buffer
if a later group fails. The tradeoff is one round trip per distinct queue and
a different queue-registration boundary on partial failure, not different
membership after success. The pipeline is not a transaction: if `SADD` executes
but `LPUSH` does not, the failed group's queue can be registered without its
jobs being delivered. Only the provably unsent case above guarantees no changes
from that group.
A lost reply after commands may have reached Redis is ambiguous: the in-flight
group may already have registered its queue and delivered jobs. It remains
unmarked for replay under the at-least-once contract, so neither absence nor
exactly-once delivery is guaranteed in that case. Existing queue membership is
not removed when a group fails.

**Anchor:** [delivery tracking and round-trip rationale](../../lib/wurk/client.rb#L447-L460),
[delivery marking](../../lib/wurk/client.rb#L583-L585),
[plain grouping and per-group SADD/LPUSH](../../lib/wurk/client.rb#L473-L498),
free [§7.1 `atomic_push` semantics](../target/sidekiq-free.md#71-atomic_push-semantics-critical-for-wire-compat),
and the public `push_bulk`
parity cases using routing middleware and real Redis:
[`test_push_bulk_registers_exactly_the_routed_queues_and_delivers_each_payload`](../../test/parity/client_push_test.rb#L397)
and
[`test_push_bulk_failure_before_second_group_leaves_only_first_queue_registered`](../../test/parity/client_push_test.rb#L427).

## Reliable fetch is the only mode; no BRPOP

**Wurk:** `Wurk::Fetcher::Reliable` (BLMOVE-based, private-list-per-process)
is the sole and default fetcher. `Sidekiq::BasicFetch` is aliased straight to
it (`lib/wurk/compat.rb:111`).

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

**Anchor:** `lib/wurk/compat.rb:111`, `lib/wurk/fetcher/reliable.rb`.

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

**Anchor:** [poll interval](../../lib/wurk/limiter/concurrent.rb#L14),
[retry loop and immediate ignore](../../lib/wurk/limiter/concurrent.rb#L87-L96),
[acquire/release key scope](../../lib/wurk/limiter/concurrent.rb#L99-L107),
[atomic acquisition and TTLs](../../lib/wurk/lua/limiter_concurrent_acquire.lua#L15-L33),
[ZREM-only release](../../lib/wurk/lua/limiter_concurrent_release.lua#L10),
[concurrent lifecycle keys](../../lib/wurk/limiter/concurrent.rb#L51-L53), and
[reset/delete scope](../../lib/wurk/limiter/base.rb#L50-L61).

## Limiter reschedule cap routes to the dead set, not re-raise

**Wurk:** `Limiter::ServerMiddleware` reschedules an over-limit job up to
`reschedule` times (default 20); once the cap is hit, the job goes straight
to the dead set tagged `rate_limited` instead of re-raising into the normal
retry pipeline (`lib/wurk/limiter/server_middleware.rb:60-63,85-93`).

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

**Anchor:** `lib/wurk/limiter/server_middleware.rb:60-63,85-93`.

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

**Anchor:** [key generation](../../lib/wurk/fetcher/reliable.rb#L87-L95),
[nonce lifetime](../../lib/wurk/component.rb#L20-L22),
[current and legacy parsing](../../lib/wurk/fetcher/private_list_key.rb#L30-L52)
and [tail shapes](../../lib/wurk/fetcher/private_list_key.rb#L56-L78),
Pro §3.2 ([Pro §3.2 Algorithm — private queue naming](../target/sidekiq-pro.md#32-algorithm)).

## Orphan reclaim moves a job tail-to-tail, not `RPOPLPUSH`

**Wurk:** `Fetcher::Reaper#drain` moves each job with
`LMOVE private_list public_q RIGHT RIGHT` (`lib/wurk/fetcher/reaper.rb`,
`drain`). The job is pushed onto the public queue's **fetch end** (the head of
the line), so a recovered job runs before the jobs already waiting.

**Spec:** Pro §3.2 documents `RPOPLPUSH private_list public_q`. `RPOPLPUSH` is
`LMOVE source dest RIGHT LEFT`: it pushes onto the public queue's *enqueue*
end, so a job recovered that way goes to the back of the line.

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

## `bulk_requeue` moves still-parked jobs to the queue head

**Wurk:** `Fetcher::Reliable#bulk_requeue` (landed in PR2, shutdown/requeue
safety fix) does an atomic per-job `LREM private 1 job` +
`RPUSH public_q job`, conditioned so the job lands in exactly one list — see
`lib/wurk/fetcher/reliable.rb` `requeue_pipelined`. Only jobs handed in as
in-progress and still parked (not yet acked) are moved, onto the queue's
fetch end, so interrupted work runs next.

**Spec:** free Sidekiq's `BasicFetch#bulk_requeue` RPUSHes in-progress jobs
back to the head of their queue (free §15, §31 gotcha 11).

**Why:** Wurk exposes this fetcher as `Sidekiq::BasicFetch`, and free
Sidekiq's head-of-queue requeue is the behaviour that name promises; it also
keeps a job interrupted by a deploy from waiting behind the whole backlog a
second time. Nothing waits for the next boot. A job is never counted
twice and never dropped if the process dies mid-move: the LREM/RPUSH pair runs
only for jobs provably still parked, and the worst case is the job staying in
the private list, where orphan reclaim picks it up.

**Anchor:** `lib/wurk/fetcher/reliable.rb` (`bulk_requeue`,
`requeue_pipelined`), PR2 (`fix/shutdown-requeue`), free §15, Pro §3.2.

## Limiter `ttl` below 24h is raised to 24h

**Wurk:** `Limiter::Base#initialize` clamps `ttl` to `MIN_TTL` (86 400s), so
no limiter key lives shorter than a day. A shorter value is accepted, not
rejected.

**Spec:** Ent §1.7 lists the `ttl` option with "Minimum: 24h".

**Why:** the floor is what the spec documents — keys that expire mid-job
orphan concurrent slots. Clamping rather than raising keeps an app that passes
a short `ttl` (legal in Sidekiq Ent) booting after the gem swap.

**Anchor:** `lib/wurk/limiter/base.rb` (`initialize`, `MIN_TTL`), Ent §1.7,
`test/parity/limiter_test.rb` (`test_no_key_lives_shorter_than_the_24h_minimum`).

## Rolling restart drives itself from the supervise loop; no einhorn

**Wurk:** `SIGUSR1` on the swarm parent enqueues every live child into
`Swarm#rolling_restart`, a state machine (`spawn_replacement → await
heartbeat → SIGTERM old slot → await exit → next`) driven entirely by the
existing non-blocking supervise loop (`lib/wurk/swarm.rb:275-277`, the
`:usr1` case at `lib/wurk/swarm.rb:527-541`, and the state machine in
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

**Anchor:** `lib/wurk/swarm.rb:275-277`, `lib/wurk/swarm.rb:527-541`,
`lib/wurk/swarm/restart.rb`, PR3 (`fix/swarm-supervision`), Ent §8.

## USR2 reopens logs; RSS recycling uses the rolling-restart machine

**Wurk:** `USR2` in a swarm child dispatches to `reopen_logs`, calling the
logger's `reopen` method if supported; it does not quiet, exit, or restart the
child. On a signal-enabled swarm parent, `drain_signals` reopens the parent's
own logger and relays `USR2` to every child. Memory checks instead go through
`Swarm::MemoryWatch#check`, whose recycle callback enqueues the affected pid via
`@restart.enqueue([pid], :recycle)` — no `USR2` trigger. A child already over the limit
within its first 60s is reported once and never recycled, so a limit below a
booted child's size cannot fork-loop (upstream recycles regardless of age).

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

**Anchor:** [ChildBoot signal table](../../lib/wurk/swarm/child_boot.rb#L30),
[child dispatch and reopen](../../lib/wurk/swarm/child_boot.rb#L229-L250),
[parent drain_signals](../../lib/wurk/swarm.rb#L527-L541),
[parent reopen](../../lib/wurk/swarm.rb#L556-L560),
[parent relay](../../lib/wurk/swarm.rb#L713-L715),
[recycle enqueue](../../lib/wurk/swarm.rb#L357-L362),
[memory check and fresh-child guard](../../lib/wurk/swarm/memory_watch.rb#L66-L78),
[manual rolling_restart enqueue](../../lib/wurk/swarm.rb#L275-L277),
[Restart deduplication](../../lib/wurk/swarm/restart.rb#L48-L54),
[replacement spawn](../../lib/wurk/swarm/restart.rb#L99-L109), and
[heartbeat/TERM/drain phases](../../lib/wurk/swarm/restart.rb#L145-L170).

## Reaper liveness has a residual local pid-reuse blind spot — shared with `super_fetch`, not fixed

**Wurk:** `Fetcher::Reaper#orphaned?` fast-paths same-boot-generation
private lists (host **and** `Component::PROCESS_NONCE` match) straight to
`Process.kill(0, pid)` (`#local_pid_alive?`,
`lib/wurk/fetcher/reaper.rb:265-276,293-303`). The nonce is
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

**Anchor:** `lib/wurk/fetcher/reaper.rb:265-276,293-303`, `lib/wurk/component.rb:20-22`,
`docs/reliability.md` (Reliable fetch → How "dead" is decided), Pro §3.2.

## Poison-pill counter resets on ACK, and a poison kill fires death handlers

**Wurk:** the recovery counter at `super_fetch:recovered:<jid>` is deleted the
moment the job acks — `Fetcher::Reliable::UnitOfWork#write_ack` pipelines the
`DEL` next to its `LREM`, so an attempt that finished (returned, or raised and
booked a retry) resets the count. Only reclaims of an attempt that never acked
accumulate toward `RECOVERY_THRESHOLD`. Past it, the reclaim script moves the job straight
from the private list into the dead set; once it returns, the kill goes through the
death-handler chain (`notify_failure` at its default `true`, `PoisonPill::Poisoned`).

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

**Anchor:** `lib/wurk/fetcher/poison_pill.rb` (`clear_in`, `mark_poison`), `lib/wurk/fetcher/orphan_reclaim.rb`,
`lib/wurk/lua/reclaim_orphan.lua`, `lib/wurk/fetcher/unit_of_work.rb` (`UnitOfWork#acknowledge`, `write_ack`),
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
`Sidekiq::Metrics::ExecutionTracker#track` (`lib/sidekiq/metrics/tracking.rb` in the upstream Sidekiq source tree, not this checkout),
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
Implementation: `lib/wurk/metrics/history.rb:67-97` and
`lib/wurk/metrics/statsd.rb:165-184` both rescue and re-raise `Job::Interrupted`.
Chain order verified in `test/unit/metrics_history_test.rb` and
`test/unit/metrics_statsd_test.rb` (the #394 real-chain tests).

**Anchor:** `lib/wurk/metrics/history.rb:67-97`,
`lib/wurk/metrics/statsd.rb:165-184`, `lib/wurk/metrics/statsd.rb:214-219`,
`lib/wurk/middleware/interrupt_handler.rb:38-40,53`,
`lib/wurk/middleware/expiry.rb:66-68,115`,
`lib/wurk.rb:343`, `lib/wurk.rb:359`, `lib/wurk.rb:366`,
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
(`JobUtil#stamp_deadline`, `lib/wurk/job_util.rb:269-274`). The two are not
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

**Anchor:** `lib/wurk/job_util.rb:269-274`, `lib/wurk/middleware/timeout.rb`,
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

## Statsd `queue.size` is sent by the leader only

**Wurk:** only the elected leader sends the `sidekiq.queue.size` gauge on each beat; every process still sends `busy`. Both carry a `process:<identity>` tag next to `queue:<name>`.

**Spec:** Ent §5.2 lists `sidekiq.queue.size` (`queue:<name>`) among the gauges every process reports ([Ent §5.2](../target/sidekiq-ent.md)).

**Why:** queue depth is one number per queue for the whole cluster. Every process LLEN-ing every queue each beat costs processes × queues commands for a value one process can read. A dashboard that takes `max` (or `last`) over the `process` tag reads the same series.

**Anchor:** `lib/wurk/heartbeat.rb` (`emit_statsd_gauges`, `emit_queue_sizes`).

## Quiet does not step the leader down; full shutdown does

**Wurk:** quiet is cluster-global and one-way, signalled with `TSTP`
(`lib/wurk/swarm.rb:224-231`, `lib/wurk/api/swarm.rb:37`
`QUIET_SIGNAL = 'TSTP'`, `lib/wurk/cli.rb:66-68`). `Launcher#quiet`
(`lib/wurk/launcher.rb:136-146`) quiets every manager and the scheduled
poller, deliberately leaves the cron poller running, and never touches
`@leader` — the renewal loop keeps renewing the lock every 15s while held
(`lib/wurk/leader.rb:190-200`) straight through a quiet. Leadership ends only
on full shutdown: `Launcher#stop` → `release_components` →
`redis_teardown_steps` (`lib/wurk/launcher.rb:355-367`, `@leader&.stop`)
→ `Leader#stop` (`lib/wurk/leader.rb:190-200`), which joins the campaign
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
on campaign loss or campaign error (`lib/wurk/leader.rb:190-200,281-286`). Full
shutdown releases the lock deliberately, periodic loops stopped before the
CAS release, rather than waiting out the TTL.

**Anchor:** `lib/wurk/launcher.rb:136-146` (`#quiet`),
`lib/wurk/launcher.rb:355-367` (`#redis_teardown_steps`),
`lib/wurk/leader.rb:190-200` (`#stop` join + release); pinned by
`test/unit/launcher_test.rb` (`test_quiet_does_not_terminate_periodic_poller`,
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
([§25.4 Routes — `GET /retries/:key`](../target/sidekiq-free.md#254-routes)); it does not explicitly define
that delimiter for every other set or POST row. The reported upstream pattern
of `key[]` plus action-named parameters is explicit in the spec only for
retries bulk ([§25.4 Routes — `POST /retries`](../target/sidekiq-free.md#254-routes)). The scheduled bulk
row lists actions, not their parameter encoding, and the morgue bulk and
single-action rows do not specify request shapes. Extending the reported
pattern to those rows is not a verified upstream fact here: no stock upstream
implementation was inspected and no compatibility test was executed for this
entry. The JSON bodies described above are verified Wurk client behavior, not
a claim that its controller accepts only JSON or that the spec requires a
particular content type.

**Anchor:** [Wurk route scope](../../config/routes.rb#L15) and
[job-set routes](../../config/routes.rb#L39-L50),
[command whitelists](../../app/controllers/wurk/api_controller.rb#L43-L48),
[single/all dispatch](../../app/controllers/wurk/api_controller.rb#L110-L148),
[bulk parameter lookup and rejection](../../app/controllers/wurk/api_controller.rb#L413-L428),
[frontend key builder](../../frontend/src/hooks/useJobSetActions.ts#L25-L30),
[single/bulk/all requests](../../frontend/src/hooks/useJobSetActions.ts#L48-L64),
[JSON encoding](../../frontend/src/http.ts#L33-L41), and
[free §25.4 Routes — retries/scheduled/morgue rows](../target/sidekiq-free.md#254-routes).

## A lost-reply Idempotency-Key stays pending until its TTL

**Wurk:** the REST API releases an `Idempotency-Key` only when the error proves the write never applied; an unknown outcome (lost reply) keeps the key pending until its TTL (1h default), so a client retry gets 409 "in progress" rather than a second enqueue.

**Spec:** no upstream equivalent (Wurk REST API).

**Why:** releasing on an unknown outcome is exactly how a retry double-enqueues.

**Anchor:** `lib/wurk/api/idempotency.rb`, `lib/wurk/client.rb`.

## `reconnect_attempts: 1` is kept — same exposure as Sidekiq #3303

**Wurk:** redis-client re-sends the one in-flight command once on a dropped socket (Sidekiq's setting). `RedisPool` never replays a block whose connection was handed out.

**Spec:** identical to Sidekiq.

**Why:** with 0, every stale socket after a Redis restart or failover surfaces as an enqueue error the pool cannot safely replay. The re-sent pop that upstream accepts as a risk does not arise here: the default scheduler claims without removing (see "The default scheduler claims due jobs instead of popping them").

**Anchor:** `lib/wurk/redis_pool.rb`.

## `JobLogger#prepare` runs inside `retrier.global`

**Wurk:** the job logger's context setup runs inside the global retry handler.

**Spec:** §14 lists `prepare` before `retrier.global`.

**Why:** an exception from `prepare` (a logger without `with_level`, a SemanticLogger quirk) would otherwise escape with the job un-ACKed in a live process's private list, stuck until restart.

**Anchor:** `lib/wurk/processor.rb`.

## An internal exception requeues the job or sends it to the dead set, and keeps the processor thread

**Wurk:** a non-`Handled` exception escaping the retry layer is reported once as `Internal exception!`, and the processor thread continues. If it is a Redis or pool error, or not a `StandardError` at all (`NoMemoryError`), the unit of work is requeued (RPUSH public then LREM private, in one script) followed by a 1s pause. Any other `StandardError` comes from the payload and would recur on every run, so the job goes to the dead set through `DeadSet#kill`, with death handlers, and is acked.

**Spec:** the exception kills the processor thread and the job stays in the private list until the process restarts (reaped then).

**Why:** a live owner's private list is never reaped, so upstream's behaviour strands the job for the life of the process. Requeuing everything instead re-ran `perform` up to ~560 times per second on a persistent failure. Residual: a Redis refusal that persists for one command and not another (ACL, WRONGTYPE on `retry`) re-runs the job at most once per second per thread, reported each time.

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

**Wurk:** `b-<bid>-complete`/`-success`/`-death` are Redis strings holding
`"1"` and meaning "already fired" (complete/success written after the enqueue,
death claimed before), and callback specs live in a `callbacks` field on
`b-<bid>`. Wurk never writes `b-<bid>-notify` or `b-<bid>-cbsucc`; they are
listed in `Batch::KEY_SUFFIXES` only so a dataset carried over from Pro gets
swept.

**Spec:** Pro [§2.8 Redis data model for batches](../target/sidekiq-pro.md#28-redis-data-model-for-batches) types
`b-<bid>-success` and `b-<bid>-complete` as **string/marker** — ":success
callbacks pending" and ":complete callbacks pending" — and types
`b-<bid>-notify` and `b-<bid>-cbsucc` as **sets**: the queued callbacks (30d
ttl) and the success-callback dedup marker.

**Why:** the two colliding keys are the *same* Redis type on both sides — a
string — with *opposite* meanings: Wurk's `"1"` says "already fired", Pro's
says "callbacks pending". Redis raises no `WRONGTYPE`, so the collision is
invisible to Redis and to the operator. The loss is event-specific: the
`EXISTS` gate reads `b-<bid>-<event>` per event, so a Pro-shaped string on
`b-<bid>-success` makes the gate return before `enqueue_callbacks` and the
`:success` callback of an in-flight Pro batch is **lost silently** — no
exception, no log line, `success_at` never stamped — while the `:complete`
callback still fires and `complete_at` still stamps, because `-complete`
carries no marker (the oracle below pins exactly this). A second, unverified
path could lose the callbacks of *every* event: Pro's §2.8 hash lists no
`callbacks` field, so a genuinely Pro-written batch (the oracle seeds its
callbacks through Wurk's API) may offer no callback specs to enqueue. Whether
Pro's marker really is a plain string, and where Pro keeps its callback specs,
stays unverifiable without a real Pro dump: R2 — Pro/Ent
Redis formats never validated vs real Pro/Ent; the fix is a real Pro+Ent Redis
dump (`docs/plans/2026/10/04/101-squeaky-clean-audit/09-production-readiness.md:12`);
E13 — `b-<bid>-success`/`-complete` used as "fired" markers vs Pro §2.8
"callbacks pending", and Pro batches lack Wurk's `callbacks` field, so validate
with a real Pro dump (`docs/plans/2026/10/04/101-squeaky-clean-audit/03-pro-ent-api.md:23`);
U8 — the human-only action that obtains that dump
(`docs/plans/2026/10/04/101-squeaky-clean-audit/11-human-actions.md:14`). Risk:
a Pro batch in flight at the swap may skip its `:success` callback. Revisit
with a dump.

**Anchor:** `lib/wurk/batch/callbacks.rb` — [marker gate and writer](../../lib/wurk/batch/callbacks.rb#L202-L219),
[callback spec reader](../../lib/wurk/batch/callbacks.rb#L325-L339),
[Pro §2.8 batch callback-marker key types](../target/sidekiq-pro.md#28-redis-data-model-for-batches), and the parity
oracle
[`test_a_pro_shaped_success_marker_suppresses_the_success_callback`](../../test/parity/batch_test.rb),
which pins the silent skip: a Pro-shaped string marker on `b-<bid>-success`
makes Wurk skip the `:success` callback while `:complete` still fires.

## Batch `b-<bid>-failinfo` is not written or imported

**Wurk:** batch failures record JIDs in `b-<bid>-failed` and update the
hash's `failures` count; terminal deaths use the `-failed`/`-died` sets.
No per-JID error JSON is persisted in `b-<bid>-failinfo`.
`Batch::Status#failure_info` always returns `[]`, including for a migrated
batch with an existing failinfo hash. Old failinfo payloads are not read or
migrated into the current failure model.

**Spec:** Pro [§2.8](../target/sidekiq-pro.md#28-redis-data-model-for-batches)
lists `b-<bid>-failinfo` as a pre-Pro 8 hash of JID → error JSON and
`b-<bid>-failed` as the Pro 8+ failed-JID set;
[§2.5](../target/sidekiq-pro.md#25-sidekiqbatchstatus) marks `failure_info`
deprecated (pre-Pro 8).

**Why:** intentionally choosing the Pro-8 failure model keeps failed-JID
tracking, not the older per-failure detail API. Migration therefore does not
make old error details available through Wurk. Unlike the carried-over tag
and callback keys, `failinfo` is absent from `Batch::KEY_SUFFIXES` and
`keys_for`: the delete, post-success linger and death TTL sweeps do not
include it. This is missing lifecycle sweeping, not a preservation guarantee;
Wurk does not manage the old hash's retention or convert its contents.

**Anchor:** [failure reader and empty compatibility method](../../lib/wurk/batch/status.rb#L63-L74),
[current failure writer](../../lib/wurk/batch/server_middleware.rb#L121-L130),
[JID-only Lua bookkeeping](../../lib/wurk/lua/batch_ack_failed.lua#L10-L17),
[death writer](../../lib/wurk/batch/death_handler.rb#L31-L38), and
[sweep key scope](../../lib/wurk/batch.rb#L70-L109).
`test/unit/batch_status_test.rb`, `test_failure_info_returns_empty_array`,
pins the empty return, not migration or retention of old failinfo hashes.

## Batch tags use a JSON field and reverse indexes, not `b-<bid>-tags`

**Wurk:** first flush writes tags as JSON in the `tags` field of `b-<bid>`
and adds the BID to each `tags:<tag>` reverse-index set. It never writes the
per-batch `b-<bid>-tags` set. Reopening a batch and reading status parse the
hash field; `BatchSet#scan_tags` reads the reverse index. A carried-over
per-batch tag set alone is neither imported nor fallback-read: without the
JSON field, batch/status tags are empty; without the reverse index,
`scan_tags` cannot discover that membership.

**Spec:** Pro [§2.8](../target/sidekiq-pro.md#28-redis-data-model-for-batches)
lists all three: the hash's `tags` field, the `b-<bid>-tags` applied-tags set,
and the `tags:<tag>` reverse index.
[§2.2](../target/sidekiq-pro.md#22-instance-api) dates the searchable-tags
API to Pro 8.1+.

**Why:** Wurk's chosen Pro-8-era model uses the JSON field and reverse indexes
for tag reads and discovery, deliberately omitting the per-batch set writer.
That is not full §2.8 format compatibility. `tags` remains in
`KEY_SUFFIXES` for cleanup of datasets carried over from Pro: `Status#delete`
unlinks the per-batch set, post-success `apply_linger` expires it to the
linger window, and death `restamp_ttls` gives it a default TTL only if it has
none (`EXPIRE NX`). These operations can expire or delete an existing set;
cleanup does not promise preservation, import or synchronization with the
JSON field and reverse indexes.

**Anchor:** [JSON and reverse-index writers](../../lib/wurk/batch.rb#L469-L496),
[reopen reader](../../lib/wurk/batch.rb#L568-L571),
[status reader](../../lib/wurk/batch/status.rb#L80-L86),
[reverse-index scan](../../lib/wurk/batch_set.rb#L68-L80),
[carried-over cleanup suffixes](../../lib/wurk/batch.rb#L77-L84),
[delete key selection](../../lib/wurk/batch/status.rb#L130-L136),
[linger expiry](../../lib/wurk/batch/callbacks.rb#L191-L195), and
[death NX expiry](../../lib/wurk/batch/death_handler.rb#L58-L61).
`test/unit/batch_status_test.rb`, `test_tags_round_trips_json`, covers the
JSON reader, not import of a Pro-shaped per-batch set.

## Batch IDs are random; the legacy global `BID` counter is unused

**Wurk:** a new batch uses `SecureRandom.urlsafe_base64(BID_BYTES)` with
`BID_BYTES = 10`. It does not allocate an ID through the global Redis `BID`
counter. A counter carried over from Pro is not consumed or advanced by this
generator, and its value does not determine new batch IDs. Reopening by an
explicit BID bypasses generation.

**Spec:** Pro [§2.8](../target/sidekiq-pro.md#28-redis-data-model-for-batches)
lists `BID` as a legacy string/global counter;
[§2.1](../target/sidekiq-pro.md#21-creation) describes a URL-safe random BID.
The spec labels the counter legacy but gives no upstream removal date.

**Why:** the chosen Pro-8 model follows random BID creation rather than
continuing a legacy allocation sequence. Existing data can still be addressed
by its explicit BID, but migration does not continue the counter or make new
BIDs monotonic. The Pro-8 model is a deliberate choice, not evidence that
every older schema row remains supported or that the counter disappeared in
a particular upstream release.

**Anchor:** [random byte count](../../lib/wurk/batch.rb#L63-L66) and
[batch ID generation/reopen](../../lib/wurk/batch.rb#L171-L173).

### Scope of the existing batch §2.8 oracle

[`test/parity/batch_test.rb`](../../test/parity/batch_test.rb#L280-L304),
`test_batch_is_visible_under_the_documented_keys`, asserts the core hash's
`description`, `total` and `pending`, live JIDs, membership in `batches`,
`tags:<tag>` reverse lookup (including `scan_tags`), then drained
`pending`/`success` hash state. It does not assert compatibility for
`b-<bid>-failinfo`, `b-<bid>-tags` or legacy `BID`, nor does it cover every
§2.8 schema row or import/retention of carried-over data. Its existence does
not resolve the callback-marker/`notify`/`cbsucc` accounting above.

The second §2.8 oracle,
[`test_a_pro_shaped_success_marker_suppresses_the_success_callback`](../../test/parity/batch_test.rb),
pins the collision itself: it seeds a Pro-shaped string marker on
`b-<bid>-success` and shows the `:success` callback suppressed while
`:complete` still fires, with no error raised and no `success_at` stamped. It
documents the silent skip; it does not resolve the callback-marker/`notify`/
`cbsucc` accounting above, and it does not stand in for a real Pro dump
(plan 101, U8 → R2).

## Encrypted job hashes are re-sealed after the chain unwinds

**Wurk:** the encryption server middleware decrypts in place for `perform`, then restores the envelope in an `ensure`; middleware outside it sees ciphertext again.

**Spec:** Ent §4.1 — `perform` sees plaintext; what outer middleware sees afterwards is unspecified.

**Why:** any later re-push of the hash must never carry plaintext.

**Anchor:** `lib/wurk/encryption.rb`.

## Periodic: late slots skipped, bare-hash `args` is one argument

**Wurk:** a periodic slot more than max(grace, 1.5× tick) late is claimed, logged as missed and not enqueued, where the grace is `mgr.grace` or 90s. The occurrence still inside that window, if any, is enqueued in its place under the same claim. A non-Array `args:` is passed as a single argument; `Loop#queue` reports the worker's queue when the loop sets none.

**Spec:** Ent §2.6 says no backfill (threshold unspecified); Ent splats `args`.

**Why:** spending the tick on the stale slot cost one more occurrence at every leader change, and a leader living under two ticks fired nothing. The occurrence due now is not a backfill. A hash splatted into keyword-ish positional args silently changes the call.

**Anchor:** `lib/wurk/cron.rb`.

## A follower rechecks the leader lock when its lease runs out, and a new leader ticks at once

**Wurk:** a follower campaigns about a second after the lease it last read expires, at most `leader_follower_interval` (60s) later. A failed campaign retries on the renew cadence. Winning the lock wakes the cron poller for an immediate tick. Lease renewal and token are `allow-oom`.

**Spec:** Ent §2.6 and §6.2: followers re-check every 60s, and on leader death a follower assumes leadership within 60s or less.

**Why:** inside the documented bound: a flat 60s left up to 90s with no lease, enough to miss every slot under churn. TTL and `SET NX` are unchanged, so a follower cannot win earlier than before. The cost is about 2 commands per 15-30s per follower.

**Anchor:** `lib/wurk/leader.rb`, `lib/wurk/cron.rb`.

## Throttle admission costs two round trips

**Wurk:** `TIME` is read in Ruby and the aligned slot key passed via `KEYS`.

**Spec:** none — `Wurk::Throttle` is a Wurk extra, not a Sidekiq surface (`lib/wurk/throttle.rb`): nothing in the Sidekiq key schema (sidekiq-free.md §1) lives under `throttle:` (`lib/wurk/keys.rb`), sidekiq-throttled keys off a host-supplied strategy name and cannot collide, and Ent's only rate-limiting surface (`Sidekiq::Limiter`, ent §1) is the rolling window Throttle deliberately does not duplicate — there is no `Sidekiq::Throttle` alias.

**Why:** a key built inside Lua breaks Redis Cluster and Dragonfly.

**Anchor:** `lib/wurk/throttle.rb`, `lib/wurk/lua/throttle_slot.lua`.

## Flow nodes with `at:` carry an `at` field and show `enqueued` once released

**Wurk:** flow node records gain a Wurk-only `at` field; a node released onto `schedule` reports state `enqueued`.

**Spec:** none — `Wurk::Flow` is a Wurk extra, not parity (`lib/wurk/compat.rb`): Sidekiq has no DAG, so nothing in its key schema (sidekiq-free.md §1) answers to `flow:` (`lib/wurk/keys.rb`), and node records live in Wurk-only `flow:<fid>:<index>` hashes nothing outside Wurk reads. The one spec-adjacent surface is compatibility, not divergence: a released `at:` node lands on the standard `schedule` zset as the exact member Client#push writes, so Sidekiq's own scheduled-job semantics take over.

**Why:** the `at` record field *is* the release score — `flow_advance.lua` HMGETs it and ZADDs the stored payload onto `schedule` with it at a release that can come long after creation; it is carried on the record (`creation.rb` writes it as a string and stores the payload as the schedule member) so the advance script never JSON-decodes the payload — the cjson rule — and the dashboard/API can show the fire time without decoding the schedule member. `enqueued` means out of the flow's hands: the script writes it before the `at:` branch, and a schedule-bound node's remaining wait is ordinary scheduler promotion, not flow state, while `waiting` would misreport already-satisfied dependencies as pending and stall every progress view reading state.

**Anchor:** `lib/wurk/flow/creation.rb:209-218`, `lib/wurk/lua/flow_advance.lua:126-143`.

## Sidekiq Enterprise / web internals not provided

**Wurk:** `Sidekiq::Enterprise::VERSION` is undefined (Wurk advertises as OSS: `Sidekiq.pro?`/`ent?` are false), and upstream's ERB dashboard internals (`Sidekiq::Web::Action`, `Route`, `Router`) and `Sidekiq::TestingClient` are not provided as upstream constants. `Sidekiq::WebHelpers` is provided as `Wurk::Web::Extension::Helpers`, a working subset of free §25.7 grown from what extensions call; helpers it lacks raise `NoMethodError`. `Sidekiq::Paginator` is provided as `Wurk::Web::Paginator`.
This is distinct from the supported `Wurk::Web::Extension::App` router DSL,
which Wurk does ship: `route(*methods, path, &block)` registers one route per
method, the verb helpers (`head`, `get`, `post`, `put`, `patch`, `delete`)
register a single method each, and `match(env)` returns a
`Wurk::Web::Extension::Action` or `nil` without executing the block.
See [dashboard extensions](../dashboard.md#custom-tabs--web-extensions) and the
[authoritative free §25.5](../target/sidekiq-free.md#255-web-router-dsl).
Supporting that DSL does not imply full upstream web-internals parity.

**Why:** the dashboard is a SolidJS SPA, and advertising Ent would make gems take Ent-only code paths that call licensed internals.

**Anchor:** `lib/wurk/compat.rb`, `test/unit/spec_constants_test.rb`.

## Sidekiq Pro version and license constants not provided

**Wurk:** `Sidekiq::Pro::VERSION` and `Sidekiq::Pro::LICENSE` are undefined.
Wurk's `Sidekiq::Pro` provides the Statsd accessor pair (`dogstatsd`,
`dogstatsd=`) as its module-level API, and never runs upstream's boot-time
license check.

**Spec:** Pro §1 lists `Sidekiq::Pro::VERSION` and `Sidekiq::Pro::LICENSE` in
the upstream module surface, and upstream raises at boot when the license is
missing or invalid ([Pro §1 Top-level constants & module — constants and license gate](../target/sidekiq-pro.md#1-top-level-constants--module)).

**Why:** there is no upstream Pro version or license value to mirror — Wurk
ships the Pro features free and never runs a license check — and advertising a
stamp would push gems onto Pro-only paths. The version-gating consequence: a
gem that reads `Sidekiq::Pro::VERSION` raises `NameError` and must gate on
`Sidekiq::VERSION` instead.

**Anchor:** `lib/wurk/compat.rb`, `test/unit/spec_constants_test.rb`.

## Old Wurk metrics keys are not read after the format restore

**Wurk:** per-class metrics written by earlier Wurk versions (`j|YYYYMMDD|…`, `<klass>-YYYYMMDD-H`) are not read; they expire within 3 days.

**Why:** no backwards-compat shims (CLAUDE.md); the restore makes Wurk read Sidekiq's own history, which is what a migration needs. True for 8.x's format only: Sidekiq 7.3 writes `j|YYYYMMDD|H:M` and `<Class>-DD-H:M`, which Wurk does not read, and 7.3 does not read Wurk's; observed by hand on 7.3.10. History starts empty on a 7.x migration. No key change: the 8.x format is the target.

**Anchor:** `lib/wurk/metrics/history.rb`.

## Metrics/profiler details

**Wurk:** `Sidekiq::Metrics::Histogram` is a module of bucket constants and the key format, not upstream's instance API; the profiler does not store upstream's `filename` field (a deleted temp path); `ProfileSet` skips a record whose hash has expired instead of raising; `JobSet#each` / `Queue#each` offsets never go below 0.

**Anchor:** `lib/wurk/metrics/histogram.rb`, `lib/wurk/profiler.rb`, `lib/wurk/profile_set.rb`, `lib/wurk/job_set.rb`.

## Busy-control HTTP request-shape parity is unsupported

**Wurk:** the engine exposes `POST /api/busy/quiet` and
`POST /api/busy/stop`, relative to the host application's mount
(`config/routes.rb:15,57-58`). The action is selected by the path:
`ApiController#quiet_process` calls `signal_processes(:quiet!)` and
`#stop_process` calls `signal_processes(:stop!)`
(`app/controllers/wurk/api_controller.rb:189-190`). The helper reads only
`identity`: absent or empty, or `"all"`, targets every live non-embedded
process; a named identity targets that process. An unknown identity returns
404, and a named embedded process is not signalled and returns count 0
(`app/controllers/wurk/api_controller.rb:464-475`). It does not select the
action using `quiet` or `stop` request parameters.

**Spec:** free [§25.4](../target/sidekiq-free.md#254-routes) specifies
`POST /busy` with `identity`, `quiet`, and `stop` parameters (per-process or
all), not split action-specific paths
([free §25.4 Routes — `POST /busy`](../target/sidekiq-free.md#254-routes)). That row does not define precedence
between the action parameters.

**Why:** the split endpoints serve the SPA's busy-page controls. Sharing
quiet/stop functionality and identity targeting does not establish HTTP
request compatibility: a client sending the specified `POST /busy` request
cannot treat Wurk's action-in-path endpoints as an equivalent contract.
This entry records unsupported request equivalence, not a proven-safe gap
or a compatibility handler; it does not infer unspecified flag semantics.

**Anchor:** free §25.4 ([free §25.4 Routes — `POST /busy`](../target/sidekiq-free.md#254-routes));
`config/routes.rb:15,65-70`;
`app/controllers/wurk/api_controller.rb:189-190,464-475`
(`quiet_process`, `stop_process`, `signal_processes`).

## `Sidekiq.redis` retries a refused connect with backoff

**Wurk:** a pool connection that is refused or times out is retried
`RedisPool::CONN_MAX_ATTEMPTS` times (3) with exponential backoff before the
error is raised — about 3.4s with nothing listening. A probe such as
`Timeout.timeout(2) { Sidekiq.redis(&:ping) }` against a dead Redis therefore
uses its whole timeout instead of failing at once.

**Sidekiq:** redis-client raises `CannotConnectError` on the first refused
connect (measured 0.001s against Sidekiq 8.1.6).

**Why:** deliberate — a Redis failover or restart drops every connection at
once, and failing every in-flight call on the first refused connect turned a
seconds-long blip into a burst of job failures in production. Test suites
that run without Redis should stub direct `Sidekiq.redis` calls
([testing](../testing.md)).

**Anchor:** [`RedisPool` connect backoff](../../lib/wurk/redis_pool.rb).

## A skipped `configure_client` block is logged in a server

**Wurk:** in a server process (unless `client_in_server`), a
`configure_client` block is skipped as upstream skips it, and the skip is
logged at DEBUG. A WARN fires at boot only when the server skipped client
blocks and ran no `configure_server` block at all — a process configured
only for the client.

**Sidekiq:** skips the block silently.

**Why:** a server that only ever received client settings (Redis URL,
middleware) runs with defaults and nothing says so; the WARN names that one
misconfiguration without logging the standard client-plus-server pattern
on every boot.

**Anchor:** [`Configuration#configure_client`](../../lib/wurk/configuration.rb),
[`BootChecks.warn_on_client_config_only`](../../lib/wurk/boot_checks.rb).

## Dashboard listing filters and filtered bulk actions are bounded

**Wurk:** the Retries, Scheduled and Dead listings' `?substr=` filter is
case-insensitive and matches a row's class, jid, error class, error message or
JSON-rendered args, examining at most 20,000 entries a request (the
`Wurk::Web::Search` budget); past that the page comes back short with
`filtered_total_exact: false`. `POST /api/<set>/all/:cmd?substr=` acts on the
matching entries only, at most 1,000 a request within the same budget, and
answers `done` plus a `cursor` to send back as `?cursor=` to continue. The
Batches listing takes `?tag=` (tagged batches, newest first, reading at most
20,000 members of the `tags:<tag>` index) and `?dead=1` (the `dead-batches`
set); `?tag=` replaces `?substr=` rather than combining with it.

**Spec:** Pro's search box is a substring over job payloads via `ZSCAN`
([Pro §10.1](../target/sidekiq-pro.md#101-mount)), the free `all/*` routes act
on the whole set ([free §25.4](../target/sidekiq-free.md#254-routes)), and Pro
lists a Dead batches tab and a tag filter without bounds or request shapes.

**Why:** an unbounded filter or sweep lets one request hold a Puma thread over
a multi-million-entry set; the cursor keeps a large filtered sweep going
without that. Without `?substr=`, `all/*` still acts on the whole set as
upstream does.

**Anchor:** [`Wurk::Api::Pagination`](../../app/controllers/wurk/api/pagination.rb)
(`match?`, `walk`, `matching`), `ApiController#sweep_matching` and `#batches`
(`app/controllers/wurk/api_controller.rb`),
[`BatchSet#tagged_snapshot`](../../lib/wurk/batch_set.rb);
`test/engine/api_filters_test.rb`.

## Dashboard and web extension differences

**Wurk:** only `POST /profiles/:key` uploads a profile (same-origin, refused in read-only mode); `GET` follows an existing upload or answers 405 (Sidekiq uploads on any GET); an engine mutation without `Sec-Fetch-Site` is accepted when Origin (else Referer) matches the request's own scheme, host and port, and refused when neither header is present (owner decision U9; Sidekiq refuses it); extension `redirect_to` inside the SPA falls back to the extension root for off-site targets (the SPA loads extensions with `fetch`, which cannot follow cross-origin redirects); `reload_page` inside the SPA goes to the extension index; `Sidekiq::Web.views` is an accepted, ignored array; read-only mode answers TRACE with 403 on the standalone mount; the health server closes connections past 16 concurrent unanswered.

**Why:** cross-site GETs must not trigger third-party uploads; the rest follow from the SPA architecture.

**Anchor:** `app/controllers/wurk/profiles_controller.rb`, `lib/wurk/web/extension.rb`, `lib/wurk/health.rb`.

## A job whose encrypted argument cannot be decrypted goes straight to the dead set

**Wurk:** a decrypt failure (unknown key version, a key resolver that returns nil or raises, a corrupt envelope) raises `Wurk::Encryption::DecryptionError`, increments `jobs.encryption_error`, and moves the job to the dead set without retries. The envelope is kept, so the job can be retried from the dashboard once the key is restored. The same happens when `encrypt` is set and the last argument is not a Wurk envelope (`Wurk::Encryption::NotSealedError`, `error_class` `Wurk::Encryption::DecryptionError`). A job with empty `args` still runs, since nothing was sealed.

**Spec:** Ent §4.6 routes a failed decrypt through the normal retry pipeline with `OpenSSL::Cipher::CipherError`. It covers a missing version or bad tag, not a last argument in no recognised envelope. Ent §4.4 says Wurk's and Enterprise's formats do not round-trip, so Enterprise ciphertext reaches this path.

**Why:** 25 retries over ~21 days cannot bring a missing key back, and each one re-logs the same failure; the dead set is where an operator looks, and a manual retry works the moment the key is back. For a last argument that is no envelope, the alternative hands ciphertext to `perform` as the decrypted value, and the job runs on garbage with no error; a plain value cannot be told from foreign ciphertext, so both stop. Documented for users in `docs/encryption.md`.

**Anchor:** `lib/wurk/encryption.rb` (`ServerMiddleware#decrypt_last_arg!`), `test/parity/encryption_test.rb` (`test_forged_tag_dead_sets_as_encryption_error_without_retry` pins the dead record tagged `encryption_error` and the absent retry entry), `test/unit/encryption_test.rb` (`test_server_middleware_dead_sets_a_last_arg_that_is_not_an_envelope`).

## Scheduled job expiry counts from the scheduled time

**Wurk:** `expires_in` on a scheduled job is measured from its scheduled run time (2h delay + 1h `expires_in` → expires 3h after enqueue).

**Spec:** Pro §7 says "the clock starts at enqueue" but its own worked example gives 3h; Wurk follows the example.

**Anchor:** `lib/wurk/job_util.rb`, `test/parity/expiring_test.rb`.

## Queue job-delete takes `jid`, not the spec's `key_val`

**Wurk:** the dashboard API deletes a single job from a queue by `jid`.
`POST /api/queues/:name/delete` is declared inside the engine's `scope :api`
block, relative to whatever mount the host chose (`config/routes.rb:15,21`;
the dummy app mounts the engine at `/wurk`, `test/dummy/config/routes.rb:10`).
`ApiController#delete_queue_job` reads `params[:jid].to_s` and calls
`Wurk::Queue#delete_job(jid)` (`app/controllers/wurk/api_controller.rb:91-96`):
a matched jid answers `{ok: true, deleted: true}`; an unmatched one answers
404 `{error: 'unknown job'}`. The supported request form is
`POST <mount>/api/queues/<name>/delete` with a `jid` parameter — the SolidJS
SPA posts JSON `{ jid }` (`frontend/src/pages/Queues.tsx:79-86`) and the
engine tests pin form params (`test/engine/api_mutations_test.rb:487-500`,
`test_delete_queue_job_by_jid`, `test_delete_queue_job_unknown_is_404`).

**Spec:** free [§25.4](../target/sidekiq-free.md#254-routes) specifies
`POST /queues/:name/delete` — "delete single job by `key_val`"
([free §25.4 Routes — `POST /queues/:name/delete`](../target/sidekiq-free.md#254-routes)). `key_val` occurs nowhere else in this
repository: no code or test reads it.

**Why:** the Ruby-level contract is parity — `Queue#delete_job(jid)` is Pro
§11's exact surface (`docs/api.md:157,453`; [Pro §11 Fast Lua API extensions — `Queue#delete_job`](../target/sidekiq-pro.md#11-fast-lua-api-extensions)),
so Ruby consumers drop in on the gem swap. Only clients scripted against
upstream's web form, POSTing `key_val`, hit the gap: a key_val-only request
leaves `params[:jid]` blank, so `delete_job('')` raises
`ArgumentError, 'jid required'` before any Redis round-trip
(`lib/wurk/api/fast.rb:20-31`), and the engine rescues only Redis errors there
(`rescue_from(*REDIS_ERROR_CLASSES)` in
`app/controllers/wurk/application_controller.rb:20`, class list at
`lib/wurk/configuration.rb:122`) — an unhandled 500, not the
`unknown job` 404, which is the unmatched-jid branch
(`app/controllers/wurk/api_controller.rb:91-96`) and is reachable only when a
jid was supplied. The endpoint is the SolidJS SPA's wire contract, not
upstream's ERB web. This entry records the divergence; it is not a sign-off
to add `key_val` support.

**Anchor:** free §25.4 ([free §25.4 Routes — `POST /queues/:name/delete`](../target/sidekiq-free.md#254-routes));
`config/routes.rb:15,21`; `app/controllers/wurk/api_controller.rb:91-96`;
`lib/wurk/api/fast.rb:20-31`;
`app/controllers/wurk/application_controller.rb:20`;
`lib/wurk/configuration.rb:122`; `frontend/src/pages/Queues.tsx:79-86`;
`test/engine/api_mutations_test.rb:487-500`.

## `:max_iteration_runtime` is accepted but not consumed

**Status:** recorded compatibility gap, not an approved safe or deliberate
exception — Wurk performs no per-iteration time-boxing.

**Wurk:** the key ships in `DEFAULTS` as `nil` (`lib/wurk/configuration.rb:32`)
and is read nowhere in `lib/`; `docs/configuration.md:157` documents it as
accepted for drop-in compatibility and not consumed. Assigning it succeeds and
changes nothing.

**Spec:** free carries the key in its DEFAULTS
([free §4.1 DEFAULTS — `max_iteration_runtime`](../target/sidekiq-free.md#41-defaults)) while the §6.4 `IterableJob` surface
([free §6.4 `Sidekiq::IterableJob`](../target/sidekiq-free.md#64-sidekiqiterablejob)) documents no reader for it — this
revision of the spec defines the option without an enforcement point.

**Why:** there is no oracle to match: implementing a time-box would mean
guessing semantics the spec has not pinned, and a wrong one kills long
legitimate iterations mid-run. An `IterableJob` that must be bounded today
needs an explicit deadline check in `each_iteration` (or `:timeout`); the gap
should close only when upstream pins what the key promises.

**Anchor:** `lib/wurk/configuration.rb:32`; `docs/configuration.md:157`; free
DEFAULTS ([free §4.1 DEFAULTS — `max_iteration_runtime`](../target/sidekiq-free.md#41-defaults)) and §6.4
([free §6.4 `Sidekiq::IterableJob`](../target/sidekiq-free.md#64-sidekiqiterablejob)).

## `WURK_PRELOAD_APP` toggles eager-load only; the parent always loads the app

**Wurk:** the swarm parent always requires the `-r` entrypoint — children
inherit the loaded app rather than re-requiring it — so the flag governs only
the extra Rails `eager_load!` (`lib/wurk/cli.rb:757-781`, deliberate-divergence
comment at `lib/wurk/cli.rb:757-781`); `preload_app?` reads
`WURK_PRELOAD_APP`/`SIDEKIQ_PRELOAD_APP` at `lib/wurk/cli.rb:757-781`.

**Spec:** Ent §7.2 — `SIDEKIQ_PRELOAD_APP=1` means "require whole app in parent
before fork" ([Ent §7.2 Environment variables — `SIDEKIQ_PRELOAD_APP`](../target/sidekiq-ent.md#72-environment-variables)), and the process-model notes
make the parent's app load conditional on the flag
([Ent §7.3 Process model — conditional parent app load](../target/sidekiq-ent.md#73-process-model)); Ent's default `0` loads the app only in the
children.

**Why:** Wurk has no unloaded-parent mode to offer. A parent that skipped the
app could not hand its object space to the forks, so children would re-require
the app one per child — losing the copy-on-write sharing the flag exists for
and multiplying boot cost by the child count. The flag keeps its documented
trade (more CoW sharing against slower parent boot); what changed is only that
the floor is "entrypoint loaded", not "nothing loaded".

**Anchor:** `lib/wurk/cli.rb:757-781`; Ent §7.2 env table
([Ent §7.2 Environment variables — `SIDEKIQ_PRELOAD_APP`](../target/sidekiq-ent.md#72-environment-variables)) and §7.3 process model
([Ent §7.3 Process model — conditional parent app load](../target/sidekiq-ent.md#73-process-model)).

## `:fork` and `:leader` extend the free spec's lifecycle events

**Wurk:** `LIFECYCLE_EVENTS` is `[:startup, :fork, :quiet, :shutdown, :exit,
:heartbeat, :beat, :leader]` (`lib/wurk/configuration.rb:114`); an unknown
event still raises `ArgumentError` (`lib/wurk/configuration.rb:114`).

**Spec:** free's `on()` set is exactly `[:startup, :quiet, :shutdown, :exit,
:heartbeat, :beat]` ([free §4.2 Public methods — `on(event)`](../target/sidekiq-free.md#42-public-methods); the same set in
DEFAULTS, [free §4.1 DEFAULTS — lifecycle events](../target/sidekiq-free.md#41-defaults)). `:fork` is Ent §7.4
([Ent §7.4 Fork callback](../target/sidekiq-ent.md#74-fork-callback)); `:leader` is Ent §6.3
([Ent §6.3 Events — `:leader`](../target/sidekiq-ent.md#63-events)), shipped 0.7.7 per the version map
([Ent §11 Version Map — 0.7.7 leader event](../target/sidekiq-ent.md#11-version-map-of-notable-api-additions)).

**Why:** both additions are Ent conformance, not free-scope drift — a drop-in
for Ent code needs `on(:fork)` to reopen non-fork-safe sockets in each child
and `on(:leader)` to fire on follower→leader transitions. The set is additive:
every free event keeps its free meaning, and a free-only consumer cannot
collide with a name it never registers. Ent's `SIDEKIQ_FORK_PER_PROCESS_HOOK`
is not modeled separately — the spec itself names `on(:fork)` as its API
([Ent §7.2 Environment variables — `SIDEKIQ_FORK_PER_PROCESS_HOOK`](../target/sidekiq-ent.md#72-environment-variables)).

**Anchor:** `lib/wurk/configuration.rb:114`,
`lib/wurk/configuration.rb:801-805`; free `on()`
([free §4.2 Public methods — `on(event)`](../target/sidekiq-free.md#42-public-methods)) and DEFAULTS
([free §4.1 DEFAULTS — lifecycle events](../target/sidekiq-free.md#41-defaults)); Ent §7.4
([Ent §7.4 Fork callback](../target/sidekiq-ent.md#74-fork-callback)) and §6.3
([Ent §6.3 Events — `:leader`](../target/sidekiq-ent.md#63-events), [Ent §11 Version Map — 0.7.7 leader event](../target/sidekiq-ent.md#11-version-map-of-notable-api-additions)).

## DEFAULTS adds `:redis_error_handlers`

**Wurk:** `DEFAULTS` carries `redis_error_handlers: []`
(`lib/wurk/configuration.rb:51`, inside the "Wurk extras, appended after the
mirrored keys" block), populated by `config.on_redis_error { |info| … }`
(`lib/wurk/configuration.rb:373`) and dispatched from `dispatch_redis_error`
(`lib/wurk/configuration.rb:373`), which logs and skips a raising handler.
Each handler gets one Hash: `{error:, attempt:, retried:, pool:}`.

**Spec:** free's DEFAULTS ([free §4.1 DEFAULTS — handler keys](../target/sidekiq-free.md#41-defaults)) has no
equivalent key, and upstream surfaces pool-level retries and give-ups nowhere —
`handle_exception` sees job and lifecycle failures, not what the pool wrapper
already absorbed.

**Why:** the pool's bounded retries are deliberately invisible to
`error_handlers` (a blip that recovers should not page anyone), but an operator
still needs the signal when retries are spent, especially on a path where the
raise re-enqueues a job. The extra key is additive by construction: the
mirrored Sidekiq prefix of `@options` stays byte-for-byte intact, so gems
introspecting the config hash see no change.

**Anchor:** `lib/wurk/configuration.rb:51`, `lib/wurk/configuration.rb:373`,
`lib/wurk/configuration.rb:1317-1318`; free DEFAULTS
([free §4.1 DEFAULTS — handler keys](../target/sidekiq-free.md#41-defaults)).

## Pool sizing: three disjoint pools per process

**Wurk:** each worker process builds three independent pools: the capsule main
pool at `max(concurrency + 5, 10)` (`lib/wurk/capsule.rb:166-171`, computed in
`main_pool_size` at `lib/wurk/capsule.rb:328-330`), a dedicated fetch pool of
exactly `concurrency` (`lib/wurk/capsule.rb:179-181`), and a dedicated web pool of
`web_pool_size` (default 5; `lib/wurk/configuration.rb:311,321,338`).
`config.redis[:size]` still pins the main pool only.

**Spec:** free [§26 `Sidekiq::RedisConnection`](../target/sidekiq-free.md#26-sidekiqredisconnection)
states per-capsule = `cap.concurrency` plus an internal/housekeeping pool of
10. That conflicts with [§5 `Sidekiq::Capsule`](../target/sidekiq-free.md#5-sidekiqcapsule),
whose `redis_pool` is `max(concurrency + 5, 10)` and whose separate
`fetch_redis_pool` is `concurrency`, matching Wurk's main/fetch sizing.
The three-pool topology (including the dedicated web pool) remains recorded
here; main/fetch sizing is not a divergence from §5. The per-capsule pool ≥
concurrency validation in [§21.4 Lifecycle](../target/sidekiq-free.md#214-lifecycle-clirun)
is kept. These conflicting sizing passages do not define one unambiguous
upstream pool topology.

**Why:** the #101 `0/N` pool-exhaustion incident: fetch's blocking `BLMOVE`
drew from the same pool as every background loop, so an idle worker could hold
main-pool slots while a dashboard burst or a heartbeat starved fetch to zero
free connections. The split is what makes "idle worker holds zero main-pool
connections" true again
(`docs/plans/2026/07/17/101-redis-resilience-audit-fixes/01-redis-resilience.md:43`);
the +5 headroom names the background loops it covers. Sizes stay overridable
(`config.redis[:size]`, `config.web_pool_size`), so a host can still approach
§26's stated sizes, without eliminating the dedicated fetch/web topology.

**Anchor:** `lib/wurk/capsule.rb:166-171`, `lib/wurk/capsule.rb:179-181`,
`lib/wurk/capsule.rb:328-330`; `lib/wurk/configuration.rb:311,321,338`; free
[§26 RedisConnection pool defaults](../target/sidekiq-free.md#26-sidekiqredisconnection),
[§5 Capsule main/fetch pools](../target/sidekiq-free.md#5-sidekiqcapsule), and
[§21.4 Lifecycle pool-size validation](../target/sidekiq-free.md#214-lifecycle-clirun).

## `reap_idle_redis_connections` sweeps from a per-pool reaper thread, not the heartbeat

**Wurk:** the setter stores `:redis_idle_timeout`
(`lib/wurk/configuration.rb:272-273`), and every pool built from the
configuration starts its own reaper thread on first checkout
(`lib/wurk/redis_pool.rb:281-290`), sweeping every `min(timeout / 2, 10)`
seconds through connection_pool's `#reap` (`lib/wurk/redis_pool.rb:322-327`).
Pools outside the launcher — web, swarm supervisor — are reaped too, because
the sweep is not tied to any heartbeat.

**Spec:** free DEFAULTS carries `redis_idle_timeout: nil`
([free §4.1 DEFAULTS — `redis_idle_timeout`](../target/sidekiq-free.md#41-defaults)) and the Config surface defines
`reap_idle_redis_connections(timeout = 60)` ([free §4.2 Public methods — `reap_idle_redis_connections`](../target/sidekiq-free.md#42-public-methods));
the spec pins the knob and its default but not the driver. Upstream Sidekiq
sweeps from its 10-second heartbeat, which is the ceiling Wurk's
`REAP_MAX_INTERVAL = 10.0` mirrors (`lib/wurk/redis_pool.rb:112-115`).

**Why:** same observable behavior — a connection idle past the timeout is
closed and its slot stays free — driven in a way that reaches pools the
heartbeat never visits, including embedded and web processes where no launcher
runs. Sweeping at half the timeout closes a connection within 1.5x of it going
idle; the 10s floor keeps a short timeout from becoming a hot loop. Requires
connection_pool >= 3.0 for `#reap` (`wurk.gemspec:52`), as Sidekiq 8.1 does.

**Anchor:** `lib/wurk/configuration.rb:272-273`; `lib/wurk/redis_pool.rb:112-115`,
`lib/wurk/redis_pool.rb:281-290`, `lib/wurk/redis_pool.rb:322-327`; free Config
surface ([free §4.2 Public methods — `reap_idle_redis_connections`](../target/sidekiq-free.md#42-public-methods)) and DEFAULTS
([free §4.1 DEFAULTS — `redis_idle_timeout`](../target/sidekiq-free.md#41-defaults)).

## Fast Lua API ships free and loads by default

**Wurk:** `Queue#delete_job`, `Queue#delete_by_class`, and the
`SortedSet#scan` block forms are mixed into the Data API at load time —
`Wurk::API::Fast::QueueExt` is included into `Wurk::Queue`
(`lib/wurk/api/fast.rb:39`) from the require in `lib/wurk.rb`
(`lib/wurk.rb:376`) — with nothing to enable and nothing to buy. Scripts are
`SCRIPT LOAD`ed once per pool and invoked by `EVALSHA`; `delete_job` returns
the deleted payload's JSON or nil and raises `ArgumentError` on a blank jid
(`lib/wurk/api/fast.rb:21`).

**Spec:** Pro §11 replaces the O(N)-in-Ruby methods with server-side Lua —
`q.delete_job(jid)`, `q.delete_by_class(MyJob)`
([Pro §11 queue deletion methods](../target/sidekiq-pro.md#11-fast-lua-api-extensions)), `scan` over every Pro SortedSet
subclass ([Pro §11 SortedSet `scan`](../target/sidekiq-pro.md#11-fast-lua-api-extensions)) — loaded at boot and cached via
`EVALSHA` ([Pro §11 script loading and caching](../target/sidekiq-pro.md#11-fast-lua-api-extensions)), with the implementation map
assigning the surface to `Wurk::API::Fast` ([Pro §13 implementation mapping — Lua API](../target/sidekiq-pro.md#13-wurk-implementation-checklist-mapping)).

**Why:** the divergence is inclusion, not behavior: names, arities, and return
contracts match Pro §11 exactly, so Pro-gated consumer code drops in. Giving it
away is pillar 2 — Pro/Ent parity in the same gem, no flags. The cost profile
is unchanged for everyone: one round trip per call, in exchange for the
script's `LRANGE` blocking Redis for its duration, which is why it is an admin
action, not a loop primitive.

**Anchor:** `lib/wurk/api/fast.rb:21`, `lib/wurk/api/fast.rb:39`;
`lib/wurk.rb:376`; Pro §11 ([Pro §11 Fast Lua API extensions](../target/sidekiq-pro.md#11-fast-lua-api-extensions)) and the
implementation map ([Pro §13 implementation mapping — Lua API](../target/sidekiq-pro.md#13-wurk-implementation-checklist-mapping)).

## Search covers queue LISTs too, with explicit scan bounds

**Wurk:** `Wurk::Web::Search` (`lib/wurk/web/search.rb:52`) scans queue LISTs
as well as the three sorted sets — `KINDS = %w[queues retry scheduled dead]`
(`lib/wurk/web/search.rb:52`) — and is deliberately bounded: at most
`SCAN_LIMIT_PER_QUEUE = 5_000` elements per queue and `SCAN_BUDGET = 20_000`
per request (`lib/wurk/web/search.rb:52`), with `truncated?` flipping when a
bound stops the scan with elements unexamined (`lib/wurk/web/search.rb:52`).

**Spec:** Pro's search is the dashboard search box on the Retry / Scheduled /
Dead pages, substring over job payloads via `ZSCAN`
([Pro §10.1 Mount — Retry/Scheduled/Dead search box](../target/sidekiq-pro.md#101-mount)); the free WebHelper of the same name serves
that box (`search(jobset, substr)`, [free §25.7 WebHelpers — `search(jobset, substr)`](../target/sidekiq-free.md#257-sidekiqwebhelpers-included-in-action-via-webapplicationhelpers)). Neither
spec defines queue-LIST coverage, a standalone Ruby class, or scan bounds.

**Why:** a LIST has no SCAN, so covering queues naively would let a keystroke
full-walk a multi-million-entry queue; the bounds are what make the extension
safe, and `truncated?` makes the partial case explicit instead of silently
wrong. The result shape is a sorted-set row plus a `:kind` discriminator and
`:name`, so Pro-shaped consumers keep their contract and the new fields are
additive.

**Anchor:** `lib/wurk/web/search.rb:24-35`, `lib/wurk/web/search.rb:52`; Pro
web search ([Pro §10.1 Mount — Retry/Scheduled/Dead search box](../target/sidekiq-pro.md#101-mount)); free WebHelpers
([free §25.7 WebHelpers — `search(jobset, substr)`](../target/sidekiq-free.md#257-sidekiqwebhelpers-included-in-action-via-webapplicationhelpers)).

## `Stats#expired`/`reset` extend the OSS Stats surface

**Wurk:** `Stats#expired` is a first-class counter snapshotted at `new`
(`lib/wurk/stats.rb:28`), `Stats::History#expired` reads the daily buckets like
processed/failed (`lib/wurk/stats.rb:274`), and `reset` with no arguments
clears `failed`, `processed`, **and** `expired` (`lib/wurk/stats.rb:104-107`).
The counter is fed by the expiry middleware, which bumps `stat:expired` and
`stat:expired:YYYY-MM-DD` when a job past its `expires_in` is skipped
(`lib/wurk/middleware/expiry.rb:105-108`).

**Spec:** free's `Stats` surface has no `expired` reader at all
([free §19.1 `Sidekiq::Stats` readers](../target/sidekiq-free.md#191-sidekiqstats)) and `reset` defaults to
`["processed", "failed"]` ([free §19.1 `Stats#reset` defaults](../target/sidekiq-free.md#191-sidekiqstats)); no `expired`
reader exists anywhere in the free spec's API surface — its sole use of the
word, [free §31 Implementation notes — Process cleanup](../target/sidekiq-free.md#31-implementation-notes--gotchas-critical-for-compat), is prose about `ProcessSet#cleanup`
pruning identities whose TTL ran out, not a Stats reader. Pro tracks an expiry
as a Statsd `jobs.expired` event when the job is skipped
([Pro §7 Job expiration — skipped-job Statsd event](../target/sidekiq-pro.md#7-job-expiration--expires_in)), not as a queryable counter.

**Why:** the server already counted expiry drops, but nothing in the Data API
could answer "where did my jobs go" without shell access to Redis; the counter
now lives beside processed/failed where an operator looks. Folding `expired`
into `reset`'s default keeps the three counters consistent — zeroing processed
while leaving expired would make the executed = processed - failed - expired
arithmetic lie. Both changes are additive: `reset` with explicit arguments is
unchanged, and the readers are new methods.

**Anchor:** `lib/wurk/stats.rb:28`, `lib/wurk/stats.rb:104-107`,
`lib/wurk/stats.rb:274`; `lib/wurk/middleware/expiry.rb:105-108`; free Stats
([free §19.1 `Sidekiq::Stats` readers](../target/sidekiq-free.md#191-sidekiqstats), [free §19.1 `Stats#reset` defaults](../target/sidekiq-free.md#191-sidekiqstats)); Pro
§7 ([Pro §7 Job expiration — skipped-job Statsd event](../target/sidekiq-pro.md#7-job-expiration--expires_in)).

## `Leader#token` exposes a fencing token Ent deliberately omits

**Wurk:** every follower→leader transition INCRs the global `leader-token` key
and stores the result on `#token` (`lib/wurk/leader.rb:120`, key constant at
`lib/wurk/leader.rb:40`), so a new leader's token is strictly greater than
every prior leader's; a re-gain after a step-down pulls a fresh token and
re-fires `:leader` (`lib/wurk/leader.rb:330-333`).

**Spec:** Ent §6 — the lock is best-effort coordination, not a strict mutex,
and "*no fencing tokens exposed to the user*"
([Ent §6 Leader Election — best-effort lock, no user fencing token](../target/sidekiq-ent.md#6-leader-election)).

**Why:** the TTL means a partition can briefly seat two leaders; Ent's answer
is "don't rely on the lock alone". The token is a strictly-additive out for
callers whose storage can compare it — reject a write stamped with a stale
token — without tightening what the lock itself promises. It is read on
transitions only, never on renewals, so behavior that worked before is
unchanged.

**Anchor:** `lib/wurk/leader.rb:40`, `lib/wurk/leader.rb:120`,
`lib/wurk/leader.rb:330-333`; Ent §6 ([Ent §6 Leader Election — best-effort lock, no user fencing token](../target/sidekiq-ent.md#6-leader-election)).

## `Sidekiq::Web` outside a Rails app routes extensions only

**Wurk:** inside a booted Rails app, `Sidekiq::Web.call(env)` serves registered
extension routes at their own paths, as a bare page without upstream's layout, and
hands every other path to `Wurk::Engine`, which runs its own `Wurk::Web.use` chain,
authorization hook and read-only gate. `mount Sidekiq::Web` therefore shows the
dashboard. Outside Rails there is no engine: `run Sidekiq::Web` dispatches only
registered Web extensions, and does not provide built-in routes such as `GET /`,
`/busy`, `/queues`, or `/retries`. After host middleware, authorization, and
read-only gates allow a request through, an unmatched safe-method path returns 404
with a body naming the fix, and logs one WARN per process. Safe methods are `GET`,
`HEAD`, `OPTIONS`, and `TRACE`; unsafe requests reaching the dispatcher without
`Sec-Fetch-Site: same-origin` return 403. Supplying that header permits routing, not
automatic success or a bypass of the outer gates.

**Spec:** free [§25.1](../target/sidekiq-free.md#251-entrypoint) exposes
`run Sidekiq::Web` through the class-level `call(env)` and specifies the CSRF
check. Free [§25.4](../target/sidekiq-free.md#254-routes) lists the built-in
routes, including the dashboard, busy, queues, and retries pages, as part of
that Web surface.

**Why:** the dashboard is the engine's SPA and JSON API, and half-serving them
without Rails would be worse than a clear 404. A gem suite that asserts upstream's
ERB home page through a bare Rack `Sidekiq::Web` (sidekiq-failures' `can display
home`) cannot pass. Upstream's probe and stats routes (`HEAD /`, `GET /stats`,
`GET /stats/queues`, `GET /dashboard/stats`) are served on every mount, this one
included (`lib/wurk/web/stats_routes.rb`).

**Anchor:** [standalone scope and safe methods](../../lib/wurk/web/rack_app.rb#L11-L21),
[outer gates](../../lib/wurk/web/rack_app.rb#L44-L53),
[CSRF check](../../lib/wurk/web/rack_app.rb#L55-L64), and
[extension dispatch](../../lib/wurk/web/rack_app.rb#L58-L75);
[engine root and JSON routes](../../config/routes.rb#L9-L16) and
[extension embedding and SPA catch-all](../../config/routes.rb#L126-L144).
Existing routing tests in
[`WebRackAppTest`](../../test/unit/web_rack_app_test.rb#L74-L107) pin
`test_get_serves_extension_route_at_its_own_path`,
`test_unsafe_method_without_same_origin_header_is_denied`,
`test_unsafe_method_with_same_origin_header_routes`, and
`test_unknown_path_is_404`;
[authorization and read-only tests](../../test/unit/web_rack_app_test.rb#L112-L150)
pin the outer gates. Spec: [free §25.1 Entrypoint — Rack call and CSRF](../target/sidekiq-free.md#251-entrypoint) and [§25.4 Routes — built-in dashboard](../target/sidekiq-free.md#254-routes).

## `Chain#add` honours a class-declared `outer_of` ordering anchor

**Wurk:** `Wurk::Middleware::Chain#add` still appends by default — any existing
entry for the class is removed and the new one lands at the tail (innermost),
exactly as free §10.1 specifies. One opt-in exception, declared per
middleware class: a class MAY define a class-level `outer_of` returning the
classes it must stay **outside** of, and `Chain#add` then places the entry
**before the first registered anchor** instead of at the tail. A class already
registered *before* that anchor keeps its slot — only its constructor args are
refreshed, because moving it would be a relocation the caller did not ask for.
With no anchor registered, `add` behaves exactly as before. Wurk's own
`Wurk::Batch::ServerMiddleware` declares
`outer_of` → `[Wurk::Middleware::Expiry, Wurk::Limiter::ServerMiddleware]`
(`lib/wurk/batch/server_middleware.rb`), resolved lazily at call time because
`Expiry` is loaded after that file. `prepend`, `insert_before`,
`insert_after` and `remove` are untouched and still relocate middleware
deliberately.

**Spec:** free [§10.1 `Sidekiq::Middleware::Chain` — `add`](../target/sidekiq-free.md#101-sidekiqmiddlewarechain) states
`def add(klass, *args) # appends (removes existing first)` — a single
append-only contract, with no anchor concept.

**Why:** the batch middleware's slot in the onion is load-bearing, and a plain
append cannot express "keep this middleware where it is". `Expiry` skips an
expired job by returning without yielding, so a batch middleware *inside* it
never reaches `ack_success`: the batch's `pending` never drops, the batch
never completes, and its `:complete`/`:success` callbacks never fire. The
Limiter turns an over-limit job into a `Limiter::Rescheduled` (a
`JobRetry::Skip`) *after* re-enqueueing it; with the batch middleware inside
the Limiter, the `OverLimit` passes through the batch's generic
`rescue StandardError` first and books a spurious failure for a job that never
ran. Before the anchor, any re-registration of the batch middleware — a
`configure_server` block, a test helper — silently relocated it inside both
and broke the accounting. The anchor is declared per class and constrains only
that class's own registration: a class that declares no `outer_of` keeps the
documented append, and a host that *wants* middleware outside an anchored one
still gets there with `prepend`/`insert_before`. The default server chain
order is unchanged (Batch → Expiry → Limiter), and nothing on the wire moves:
no Redis key, job-JSON field or Lua script is touched.

**Anchor:** [anchor-aware `add`](../../lib/wurk/middleware/chain.rb#L70-L94),
[anchor resolution](../../lib/wurk/middleware/chain.rb#L173-L177),
[batch middleware's `outer_of`](../../lib/wurk/batch/server_middleware.rb#L46-L67),
free [§10.1 `Sidekiq::Middleware::Chain` — `add`](../target/sidekiq-free.md#101-sidekiqmiddlewarechain).

## Web pool is configuration-owned; the class-level accessor and pool-bound mounts are unsupported

**Wurk:** `Sidekiq::Web` is an alias of `Wurk::Web` (`lib/wurk/compat.rb:203`),
and `Sidekiq::Pro::Web` is that same class (`lib/wurk/compat.rb:57`). `Wurk::Web`
exposes no class-level `redis_pool` reader and no `redis_pool=` setter — both
raise `NoMethodError` — and no `.with` factory, so
`mount Sidekiq::Pro::Web.with(redis_pool: POOL)` cannot be expressed. The
class-level surface is the config/extension surface
(`lib/wurk/web/config.rb:390-456`); `Wurk::Web`'s own class body is empty
(`lib/wurk/web.rb:27-28`). The only `redis_pool` under `lib/wurk/web` is
`Wurk::Web::PoolScope::Handle#redis_pool` (`lib/wurk/web/pool_scope.rb:39-43`),
an instance method on a duck-type handle that returns
`Wurk.configuration.web_redis_pool` — not the class-level accessor. The
dashboard pool is the configuration-owned `config.web_redis_pool` reader
(`lib/wurk/configuration.rb:336-338`): read-only, with no `web_redis_pool=`
setter, so Wurk builds the pool itself from the same `config.redis` options the
worker pools use (`lib/wurk/configuration.rb:1305-1309`) and sizes it with
`config.web_pool_size` (`lib/wurk/configuration.rb:314-321`, default 5). Every
dashboard request runs on that pool.

**Spec:** free §25.1 lists `Sidekiq::Web.redis_pool = my_pool` in the entrypoint
surface and marks it "Upstream Sidekiq only; unsupported in Wurk
(NoMethodError)", naming `config.web_redis_pool` as the reader and
`config.web_pool_size` as the sizing knob
([free §25.1 Entrypoint](../target/sidekiq-free.md#251-entrypoint)). Pro §10.2
documents `Sidekiq::Pro::Web.with(redis_pool:)` returning a Rack app bound to
that pool, so one process can monitor several shards
([Pro §10.2 Multi-shard](../target/sidekiq-pro.md#102-multi-shard)).

**Why:** the dashboard pool is configuration-owned because Wurk keeps three
disjoint pools per process (main, fetch, web — see
[Pool sizing](#pool-sizing-three-disjoint-pools-per-process)): the dedicated
web pool and its short checkout timeout are what keep an API burst or a
long-lived SSE stream from draining the connections a co-located worker needs
to fetch and heartbeat (#101). A class-level pool handle would let any gem swap
that pool out from under every request path, and it is global mutable state
set before boot: the parent closes its sockets before forking
(`lib/wurk/swarm.rb:401-405`) and each child drops the inherited pools and
builds fresh ones (`lib/wurk/swarm/child_boot.rb:160-161`), so a
caller-assigned pool could not survive the fork boundary — it would be an
inherited socket, not a fresh pool.
Per-mount shards would need a pool and a teardown per mount, which the
engine's single dashboard mount does not have. The cost of the choice is real
and the migration guide states it: the dashboard cannot be pointed at a
different Redis than the workers use — only its size is configurable — and a
shard-per-mount deployment has no Wurk equivalent.

**Anchor:** [`Sidekiq::Web` alias](../../lib/wurk/compat/web.rb#L6) and
[`Sidekiq::Pro::Web` alias](../../lib/wurk/compat/web.rb#L14); the
[class-level Web surface](../../lib/wurk/web/config.rb#L390-L456) and the
[empty `Wurk::Web` class body](../../lib/wurk/web.rb#L27-L28);
[`PoolScope::Handle#redis_pool`](../../lib/wurk/web/pool_scope.rb#L39-L43);
[`config.web_pool_size`](../../lib/wurk/configuration.rb#L314-L321),
[`config.web_redis_pool`](../../lib/wurk/configuration.rb#L336-L338) and
[`build_redis_pool`](../../lib/wurk/configuration.rb#L1305-L1309);
[parent sockets closed before fork](../../lib/wurk/swarm.rb#L401-L405) and
[child pools rebuilt after fork](../../lib/wurk/swarm/child_boot.rb#L160-L161);
free §25.1 ([free §25.1 Entrypoint](../target/sidekiq-free.md#251-entrypoint))
and Pro §10.2 ([Pro §10.2 Multi-shard](../target/sidekiq-pro.md#102-multi-shard));
the user-facing statement is [migration guide §7](../migrate-from-sidekiq.md#7-known-incompatibilities--what-not-to-expect);
the unsupported accessors are pinned by
[`test_sidekiq_web_class_level_redis_pool_accessors_are_unsupported`](../../test/unit/web_config_test.rb#L531-L542).

## Negative and non-integer queue weights are rejected at boot

**Wurk:** `Capsule#queues=` raises `ArgumentError` for a queue weight that is
negative or not an integer. A weight of `0`, or none at all, means unweighted.

**Spec:** free §5 documents `"name"` or `"name,weight"` and says nothing about
invalid weights. Stock Sidekiq accepts them.

**Why:** a nonsense weight is a config typo. Refusing to boot surfaces it at
deploy, where accepting it would quietly change how often a queue is served.

**Anchor:** `lib/wurk/capsule.rb` (`parse_queue_entry`), free §5,
`test/unit/capsule_test.rb`.

## A live worker re-queues payloads stranded in its own private list

**Wurk:** on every reaper tick a worker compares its own private lists with what its threads and pending ACKs hold. A payload accounted for by neither, seen stranded twice at least 30s apart, goes through the same reclaim script as a dead owner's list (`Fetcher::OrphanReclaim`): back to its public queue, counted by the poison pill, or past the cap straight into the dead set.

**Spec:** Pro §3.2 reclaims private lists only when the owner is dead.

**Why:** a claim whose reply was lost leaves a job in a live owner's list, and the owner never settles what it does not know about. That is up to one job per thread per Redis restart or stall, indefinitely on a stable fleet. A running job holds a claim for all of `perform` and is never touched.

**Anchor:** `lib/wurk/fetcher/self_reconcile.rb`, `lib/wurk/fetcher/orphan_reclaim.rb`, `lib/wurk/fetcher/reliable.rb` (`CLAIM_KEY`).

## The reaper's grace is a local clock, not OBJECT IDLETIME

**Wurk:** a heartbeat-judged orphan waits out 30s on the sweeping process's own clock, finished by that process with or without the sweep lock, and is drained only if the heartbeat is still missing. An owner in this process tree (same host and nonce) skips it: `kill(0)` answers.

**Spec:** Pro §3.2 does not specify a grace.

**Why:** `OBJECT IDLETIME` is reset by any read, is refused under LFU policies and missing on Dragonfly. A missing hash does not prove death: `processes` has no TTL, so a Redis restarted from a snapshot over 60s old shows every live worker as lapsed until its next beat, and 25 CPU-bound jobs held a beat back 17.4s (at a 15s grace, one trial in nine drained all 25 live jobs). Reclaim after losing a host takes 90-141s measured, against 1.2s for a swarm child.

**Anchor:** `lib/wurk/fetcher/orphan_grace.rb`, `lib/wurk/fetcher/reaper.rb`.

## Workers keep claiming at maxmemory through an allow-oom script

**Wurk:** on an OOM refusal the fetcher claims via `#!lua flags=allow-oom`, writing the identity hash and `beat` in the same script. Failing jobs book retry and dead-set entries the same way, and the reaper's move too, and its sweep lock, shutdown requeue and self-reconcile. Enqueues stay refused.

**Spec:** Free's `BRPOP` is not refused at maxmemory. Pro §3 does not specify this.

**Why:** with reliable fetch as the only mode, `LMOVE` being refused would make a full Redis a deadlock no worker can clear. Dragonfly compiles no shebang, so the scripts live outside `lib/wurk/lua/` (uploaded at boot) and go by EVAL; a server refusing them raises the original error. Dragonfly refuses all of these, so every multi-key move there adds before it removes; `LMOVE` itself remains exposed on the fetch path, see docs/reliability.md.

**Anchor:** `lib/wurk/fetcher/oom_drain.rb`, `lib/wurk/fetcher/at_maxmemory.rb`.

## Valid JSON that is not an object goes to the dead set

**Wurk:** `[1,2]`, `123`, `true`, `"x"`, `null` in a queue are treated like unparseable JSON: reported as `Invalid JSON`, written raw to the dead set, acked.

**Spec:** free §14 sends a payload that fails to parse to the dead set and does not address non-object JSON.

**Why:** there is no job in it to run. These used to hot-loop or vanish.

**Anchor:** `lib/wurk/processor.rb` (`parse_or_kill`).

## The default scheduler claims due jobs instead of popping them

**Wurk:** `Scheduled::Enq` rescores up to 10 due members to a 60s lease with `scheduled_claim`, pushes each through the client chain, then `ZREM`s them in one round trip. `LUA_ZPOPBYSCORE` stays public but no longer runs.

**Spec:** sidekiq-free.md §16 lists `Scheduled::Enq::LUA_ZPOPBYSCORE`, and §1.8 the pop-one-due-entry step: a destructive pop, then a push.

**Why:** that order loses the job when the push and any write-back are refused (a store at maxmemory), when redis-client re-sends a pop whose reply was lost (Sidekiq #3303), and on a crash between the two. Measured against real Redis: 50 of 50 lost at maxmemory, 4 of 40,000 lost across four 4s stalls with no error. Making `reliable_scheduler!` the default is no answer because it skips client middleware on promotion. The key, payload bytes and score format are unchanged; a member's score reads as the lease expiry while claimed. Sidekiq processes sharing the Redis during a cutover skip claimed members, as their score is no longer due. Cost: a failure between the push and the `ZREM` runs the job again, at most 10 per crash, and a claimed member stranded by a crash waits out the lease.

**Anchor:** `lib/wurk/scheduled.rb`, `lib/wurk/lua.rb`.

## `reliable_push` skips the drain while its circuit is open

**Wurk:** after a failed push to a Redis, later plain pushes to it buffer without trying, and a drainer thread (started on that failure if none is running) probes and replays. The circuit closes on a full replay, on any server answer, or after 30s by itself.

**Spec:** sidekiq-pro.md §5: "Each subsequent `push` first attempts to drain the buffer (oldest-first) before pushing the new job."

**Why:** with Redis down, attempting that drain and then the push cost every caller 6s (36s against a hung server), which makes a web request unusable and defeats an outage buffer. Oldest-first replay and the buffer's other guarantees hold. Cost: after recovery a buffered job waits for the drainer's tick (default 2s) instead of the next push, and the process gains one thread once a push has failed.

**Anchor:** `lib/wurk/client/buffered.rb`.

## Scheduler first sweep waits 10-15s

**Wurk:** `Poller#initial_wait` is `INITIAL_WAIT + rand * 5`.

**Spec:** sidekiq-free.md §16 shows `INITIAL_WAIT = 10`; the constant keeps that value.

**Why:** at exactly 10s, a fleet booted together sends every first sweep in one 250ms window (measured, 12 processes).

**Anchor:** `lib/wurk/scheduled.rb`.

## Fetch-loop errors are coalesced before `error_handlers`

**Wurk:** per process and exception class, the fetch loop reports the first error, then one per 60s with `suppressed` in the context. `wurk_fetch_errors_total` counts all of them. Other paths are untouched.

**Spec:** free §14 sends fetch errors through the error handlers.

**Why:** the loop retries every second on every thread of every process, so one outage produced hundreds of thousands of reports at a production adopter.

**Anchor:** `lib/wurk/configuration.rb` (`report_fetch_error`), `lib/wurk/processor.rb`.

## `wurkswarm` exits when the fleet cannot stay up

**Wurk:** exit 1 after `swarm_crash_exit_after` (default 600s) of every slot crash-looping; `nil` restores respawning forever. A crash from an unreachable Redis does not count.

**Spec:** Ent documents no such exit; supervision respawns children.

**Why:** a parent respawning forever reads as Running to orchestrators and process-grep probes while processing nothing.

**Anchor:** `lib/wurk/swarm.rb`.

## One reaper sweep per interval covers every list; there is no hourly full sweep

**Wurk:** every 60s one process, under a lock of 48s, runs one `SCAN` and acts on every private list, whichever queues it serves.

**Spec:** Pro §3.2 documents a sweep "1/min within process group" and a "full SCAN 1/hr".

**Why:** the one-minute lock is shared across the fleet, so a sweep scoped to the winner made a queue served by 1 process of 10 wait about 13 intervals. The SCAN is one pass either way, so scoping saved nothing. A lock TTL of a whole interval made a sole survivor skip alternate sweeps.

**Anchor:** `lib/wurk/fetcher/reaper.rb`.

## Fetch on a full Dragonfly can lose a job between shards

**Wurk:** the fetch path uses plain `LMOVE`/`BLMOVE` on every server. On Dragonfly near `maxmemory`, between shards, these can pop the job, drop the push and return it, so the job runs with no private copy. The reaper and requeue paths do not use `LMOVE` for this reason.

**Spec:** Pro §3 assumes an atomic move.

**Why:** `BLMOVE` has no script form, so a client-side fix means polling on the hot path for every server or a backend fork, and a keyspace hash tag would change the key schema. Accepted and documented: keep a Dragonfly job store below `maxmemory`.

**Anchor:** `lib/wurk/fetcher/reliable.rb`, `docs/reliability.md`.

## The scheduler's claim window follows the server clock

**Wurk:** `scheduled_claim` takes the earlier of the caller's `now` and the server's `TIME` as its window, and releases score from the server's clock too.

**Spec:** free §16 passes `now` from the client.

**Why:** a lease on a local clock lets a host running behind cut another host's lease short, and one running ahead hold a released member out for as long as its skew. Cost: mocking the process clock forward no longer promotes a job (`Timecop.mock_process_clock = true` moved +2h). `travel_to` and plain Timecop don't touch that clock and are unaffected. Tests that need promotion should make the member due.

**Anchor:** `lib/wurk/lua.rb`, `lib/wurk/scheduled.rb`.

## `Wurk::Sentry` `report_after_attempts` differs from `report_after_job_retries`

**Wurk:** reports attempt N and the terminal attempt, at most two events, rather than every attempt from N on.

**Spec:** sentry-sidekiq is a separate gem; listed because the migration table compares them.

**Why:** the point is an early first alert, without the volume of reporting each later attempt.

**Anchor:** `lib/wurk/sentry.rb`.

## A worker refuses `Sidekiq::Testing` modes

**Wurk:** `Wurk::CLI#run` after booting the app, `Swarm::ChildBoot#run` before the `:fork` and `:startup` hooks, and `Wurk::Embedded#run` call `Swarm::TestModeGuard.enforce!`: with fake or inline mode on, they log an ERROR naming the likely cause and call `Testing.disable!`.

**Upstream:** Sidekiq 8.1.5's `sidekiq` CLI, observed from outside with `Sidekiq.testing!(:fake)` at load, starts normally, logs nothing about it, and every enqueue returns a jid and never reaches Redis.

**Why:** a worker that drops every job without a word is never what anyone wants, and `rspec-sidekiq` outside a test group causes exactly that because the swarm preloads the default group. The divergence only changes a state that loses jobs. A Rails web process enqueuing in fake mode is not covered, and the guard stands down under `RAILS_ENV=test` or `RACK_ENV=test`, where `disable!` would take fake mode from a whole suite that boots a worker in-process.

**Anchor:** `lib/wurk/swarm/test_mode_guard.rb`, `lib/wurk/cli.rb`, `lib/wurk/swarm/child_boot.rb`, `lib/wurk/embedded.rb`, `test/integration/worker_test_mode_guard_test.rb`.

## `wurkswarm` loads a Rails target's `config/application.rb` before the group preload

**Wurk:** loads `config/application.rb` first, then the Bundler groups. If that file raises `NameError`, the process re-executes itself once with the preload first, keeping its pid, ENV, argv and cwd.

**Spec:** Ent §7.3: `sidekiqswarm` preloads the Bundler groups, then requires the app.

**Why:** gems that need Rails at require time fail under the stock order, and apps written for the stock order fail under the other. Only attempting tells them apart, and a fresh process leaves no half-run class body behind.

**Anchor:** `lib/wurk/cli.rb` `load_rails_framework`.

## `Sidekiq.server?` is a runtime worker flag, not a namespace probe

**Wurk:** `Sidekiq.server?` reports whether this process is running workers. It is false in a client process and true in a worker process.

**Spec:** the free spec describes `server?` as "true if Sidekiq::CLI defined" — a namespace probe rather than a runtime flag.

**Why:** Wurk aliases `Sidekiq::CLI` unconditionally, so the upstream namespace probe would answer true in every Wurk process, including a web process that only enqueues jobs. Wurk's flag preserves the observable outcome the probe is used for: false in a client process, true in a worker. The implementation of the probe is not observable; the runtime answer is.

**Anchor:** `lib/wurk/compat.rb`, `lib/wurk.rb`.

## The logging context lives under `:wurk_context`, not `:sidekiq_context`

**Wurk:** `Sidekiq::Context` stores its thread-local logging context under `Thread.current[:wurk_context]`. A context added on one thread is not visible on another.

**Spec:** the free spec names the thread-local key `Thread.current[:sidekiq_context]`.

**Why:** the key is an internal storage detail of the logging context, not part of the public `Sidekiq::Context.with` / `.add` surface. The observable behaviour — a thread-local context that the public API reads and writes — is unchanged; Wurk keeps its own key so the two implementations cannot collide on a shared thread-local slot.

**Anchor:** `lib/wurk/context.rb`.
