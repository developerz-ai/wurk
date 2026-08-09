# 10 — Global per-queue concurrency: what happens to a slot after the fetch

> Settles steps 4, 5 and 6 of [`10-global-concurrency.md`](10-global-concurrency.md).
> Written after implementing them, so every claim below is one a test pins.

The slot model (`lib/wurk/lua/queue_slot.lua`) and the gated fetch
(`lib/wurk/fetcher/capped.rb`) decide who is *admitted*. This is the other half:
who stops holding capacity, when, and what the cluster looks like while a deploy
is in flight.

## Release: one anchor, not five

`Processor#process`'s `ensure` is the only place a slot is given back.

That frame is the one every exit path passes through — a clean return, a raised
failure, a scheduled retry, `JobRetry::Handled`, the watchdog's asynchronous
`Thread#raise` for a `timeout:`/`deadline:` bound (slice 08), and the shutdown
raise. A release written into any single arm is a release the next arm added
forgets, and a forgotten one strands cluster-wide capacity for the whole 60s
TTL. There is deliberately no happy-path `release` call anywhere.

**It costs nothing.** The `ZREM` is written into `UnitOfWork#write_ack`, so it
rides the pipeline the ACK already rides — the one the *next* fetch opens
(`Fetcher::Reliable#defer_ack`). A capped job therefore costs the same single
round trip on the way out that it costs on the way in, and the release always
lands ahead of the claim it is pipelined with: a thread re-competing for the
queue it just ran releases before it asks, never after.

Two consequences worth naming:

* The release is **deferred**, exactly as the ACK is. Between a job finishing
  and its thread's next Redis touch the hold is still in the ledger. That window
  is one loop iteration on a busy worker, and every path that stops fetching
  flushes it (`#flush_pending_acks`) — including the pass that parks in BLMOVE
  or sleeps out a capped-queue backoff, so a thread never idles while holding
  capacity.
* `Wurk::Shutdown` is the one path that must **not** ACK: the payload stays in
  the private list to be requeued and re-run elsewhere. Whoever re-runs it needs
  the capacity, so that path releases on its own
  (`UnitOfWork#release_slot`) rather than waiting out the TTL. One round trip,
  bounded to the jobs a hard shutdown kills mid-flight.

## Refresh: on the beat, never a timer

A hold expires so that a SIGKILLed holder's capacity comes back with no operator
action. That only works if a live holder keeps saying it is alive — and this
process already says so every `Heartbeat::BEAT_PAUSE` seconds.

So the refresh joins the beat: `Heartbeat#write_beat` appends one `EVALSHA
refresh_slots` covering every hold in `QueueSlot::HELD`, to the idempotent
pipeline that was going out anyway. **No new beat traffic**, and one call however
many slots this process holds. A process holding nothing — which is every
process in an install that caps no queue — queues nothing at all, so the whole
feature costs it one Hash read per beat.

`ZADD XX`, never a plain `ZADD`: a refresh may only extend a hold this process
still has. A hold that already aged out has had its capacity handed to someone
else, and re-adding the member would put the queue over its cap with two holders
that each believe the slot is theirs. Losing it instead runs that one job off the
books — an under-count that converges the moment the job's release names a member
that is already gone.

The beat is wrapped in `Lua::Loader.pipelined_eval` for this: a pipelined
`EVALSHA` surfaces `NOSCRIPT` only when the pipeline finalizes, so a flushed
script cache would otherwise cost this process *every* beat until some other
caller happened to reload the script.

## Quiet / TSTP: hold what you are spending

A quieted process stops fetching, so it takes no further slots, and
`Fetcher#terminate` flushes the ACKs it is holding — each of which carries the
release of the slot its job ran under. What is left is exactly the slots the
still-draining jobs are using.

That is the intended reading of "a quiet process releases its slots": it holds
capacity it is **spending**, never capacity it is only reserving. Releasing a
running job's slot at quiet time would be the actual bug — the job is still
running, and the cap would be over-admitted for the length of the drain.

## Rolling restart: tolerated, and bounded

**Decision: tolerate it. Do not fix it.**

`Swarm::Restart` boots the replacement child and waits for its heartbeat *before*
it TERMs the old one (`spawn_replacement → await_heartbeat → term_old →
await_exit`). For the length of one drain both generations are live, so a capped
queue can briefly run over its cap by up to the old child's in-flight count.

Neither alternative is better:

* **Starve the replacement** until the old child's last job finishes — the deploy
  now stalls behind the slowest job on that queue, and the whole point of
  spawning the replacement first is that it is warm before the old one goes.
* **Hand capacity between processes** — that needs a transferable count, which
  is the counter this ledger exists not to be (`queue_slot.lua`): a counter
  cannot tell a leaked unit from a busy one, so a child SIGKILLed mid-handover
  takes the capacity with it forever.

The excess is bounded three ways: by the old child's in-flight job count, by one
`drain_timeout`, and — if that child is SIGKILLed rather than drained — by the
60s hold TTL. A cluster-wide cap is a ceiling on steady-state concurrency, not a
transactional invariant across a deploy; Oban Pro's and BullMQ's global limits
make the same trade.

## Known windows, written down rather than papered over

* **Deferred release, above.** One loop iteration on a busy worker; flushed by
  every path that stops fetching.
* **A flush that fails and is restored.** `#restore_pending_acks` hands an ACK
  back to a thread that may since have claimed a new slot on the same queue, and
  a holder token is per *thread*, not per job — so a later standalone flush of
  that stale ACK can release a live hold. It needs a Redis error plus a
  concurrent flush from another thread while a job runs; the result is one slot
  over-admitted for the rest of that job, self-healing. Cheaper to name than to
  close with a per-claim token, which would cost the script's
  replay-convergence arm.
* **A cap changed mid-deploy.** Capacity is passed in by the caller rather than
  stored, so both generations ask for their own number and the larger one is in
  force until the last process running it stops fetching. Deliberate — see
  `queue_slot.lua`.
