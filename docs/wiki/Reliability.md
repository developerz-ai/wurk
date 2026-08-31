# Reliability

Wurk's delivery guarantee is **at-least-once, on by default**. There is no basic-fetch mode to opt out of and no Pro toggle to turn on: `Wurk::Fetcher::Reliable` is the only fetcher, and every fetch is an atomic move rather than a destructive pop.

```
LMOVE  queue:default  queue:default|web-1|4711|<nonce>|0  RIGHT LEFT
```

The payload sits in that per-process **private list** for the whole of `perform` and leaves only on an ACK (`LREM`). At every instant the job exists in Redis, in exactly one of the public queue or one private list — which is why `SIGKILL`, an OOM kill, a lost instance or a container eviction cannot lose work.

## What recovers it

| Death | Mechanism |
|---|---|
| `SIGTERM` drain | Pending ACKs flushed, then whatever is still running at `shutdown_timeout` is moved private list → public queue by an LREM-guarded `RPUSH` |
| `SIGKILL`, OOM, vanished host | The reaper: a scoped `SCAN` every 60s and a full keyspace pass hourly, both behind a `SET NX EX` lock so exactly one process in the fleet sweeps, plus an unguarded boot-time sweep so a replacement recovers its dead sibling immediately |

Liveness is decided per owner: same host *and* same process nonce ⇒ `Process.kill(0, pid)`, authoritative and instant; any other incarnation ⇒ the heartbeat, which has a 60s TTL and so can lag reclaim by up to a minute.

## Duplicate execution is the price, and it is real

A process that dies **mid-`perform`** has its job re-run **from the top**. Every write, email, charge and API call the first attempt completed happens again — Wurk cannot know how far it got. This is the at-least-once contract, identical to Sidekiq Pro's, and the mitigation is idempotent jobs, not configuration. Key side effects on `order.id`, use upserts, send an idempotency key, and make the job re-entrant.

The window is slightly wider than Pro's, deliberately: the ACK is pipelined with the **next** fetch to spend one round trip per job instead of two. It is flushed before blocking, idling, quiet, stop and shutdown, so no graceful path is affected, and nothing can be *lost* — the payload leaves the private list later, never earlier.

## The three things that can still lose a job

- **Redis itself.** The guarantee starts at "the payload is in Redis". No AOF, or a failover to a replica that missed the write, and the job is gone. Persistence policy is yours.
- **The default scheduler.** `Wurk::Scheduled::Enq` pops due jobs from `retry`/`schedule` and then pushes them — between the two, the job exists only in the poller's memory. `config.reliable_scheduler!` closes that with a single atomic Lua promote (push before remove). **Reliable fetch is the default; the reliable scheduler is not.**
- **The client outage buffer.** `Wurk::Client.reliable_push!` turns an enqueue during a Redis outage into an in-process ring buffer instead of a raise — but it is in-memory and per-process, so a process death loses every buffered job, and `:drop_oldest` (the default) silently evicts once full. It is a bounded window over a short blip in a surviving process, not a durable outbox. If losing an enqueue is unacceptable, write the intent into your own DB inside the business transaction.

Batch payloads are never buffered — their Lua has atomic counter side effects that cannot be safely replayed — so they re-raise even in a mixed `push_bulk`.

## Also worth knowing

`Wurk.transactional_push!` defers the Redis write to the surrounding DB transaction's commit, killing the classic "job runs before the row exists" bug; the `jid` is still allocated synchronously. And a Pro initializer drops in unchanged: `super_fetch!` is effectively a no-op (its block is still honoured as the recovery callback), while `reliable_scheduler!`, `reliable_push!` and `fetch_poll_interval` are real calls.

Reaper internals, the pid-reuse blind spot, fork semantics of the buffer, the paused-queue cache, the recorded divergences from Pro, and what to monitor: **[docs/reliability.md](https://github.com/developerz-ai/wurk/blob/main/docs/reliability.md)**.
