# Parity Divergences

Wurk targets 100% wire/behavioral compatibility with Sidekiq + Pro + Ent
(`docs/target/sidekiq-{free,pro,ent}.md`). Parity tests are oracles — any
divergence from them is a bug unless recorded here as intentional.

Each entry: what Wurk does, what the spec says, why the divergence is safe
and deliberate, and the anchor to revisit if the spec or upstream changes.

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
