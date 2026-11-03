# Architecture

Wurk runs jobs with **fork-based real parallelism** — a parent process forks N children, each running a thread pool. This sidesteps the GIL for CPU-bound work while staying wire-compatible with Sidekiq.

## Layers

Each class has one reason to change.

| Layer | Owns |
|---|---|
| **Swarm** | Parent process; forks N children, PID supervision, rolling restart |
| **Launcher** | Top of each child: Managers, scheduler poller, heartbeat |
| **Manager** | One per Capsule: thread pool, lifecycle |
| **Fetcher** | Reliable fetch: atomic `LMOVE`/`BLMOVE`, main queue → per-process private list |
| **Processor** | Takes a unit of work from the Fetcher, runs the middleware chain, invokes `perform`, ACKs |
| **Client** | Enqueue, Lua bulk path, Redis-outage local buffer |
| **Middleware** | Client + server chains (the Sidekiq contract) |
| **Web** | Engine-mounted precompiled SolidJS SPA + JSON APIs |
| **RedisPool** | Per-process pool over redis-client |

The default fetcher is **reliable**: an atomic `LMOVE` (`BLMOVE` when parked on an empty queue) moves a job from the main queue to a per-process private list, so a `SIGKILL`'d worker never loses in-flight jobs — they're reclaimed on the next boot.

## Boot ordering

1. Host app boots fully; initializers run; eager-loaded constants resolve.
2. Host `after_initialize` hooks run, then the railtie's boot initializer fires last.
3. The swarm closes parent-side connections that must not survive a fork (DB, Redis).
4. The swarm forks N children.
5. Each child opens a fresh Redis pool (Active Record reconnects through its own fork hook), then starts fetching.
6. The parent enters its supervision loop.

This is why **a Redis socket is never shared across a fork** — parent sockets are closed before forking and reopened inside each child.

## Signals

| Signal | Target | Effect |
|---|---|---|
| `SIGTERM` / `SIGINT` | parent | Graceful drain; relayed to children; in-flight finishes to `shutdown_timeout`, then exit |
| `SIGTSTP` | parent | Quiet globally: relayed to children, each stops fetching; in-flight continues. **One-way — there is no resume**; send `SIGTERM` to shut down |
| `SIGUSR1` | parent | Rolling restart: fork a replacement, wait for heartbeat, `SIGTERM` the old slot, repeat |
| `SIGUSR2` | parent, child | Reopen log files (logrotate) |
| `SIGTTIN` | parent, child | Dump thread backtraces |
| `SIGKILL` | any | Safe — private-list entries stay in Redis and are reclaimed once the owner's heartbeat expires: about 1s for a swarm child, 90s after a pod restart, 90-140s for a lost host |

## Platforms

Ruby `>= 3.2.0`, Redis `>= 7.0.0`. Without `fork` (JRuby, TruffleRuby, Windows; untested in CI) only the single-process `wurk` runner and `config.wurk.embed_in_web` apply: `wurkswarm` and the railtie's swarm have no fallback.
