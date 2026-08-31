# Architecture

Wurk runs jobs with **fork-based real parallelism** — a parent process forks N children, each running a thread pool. This sidesteps the GIL for CPU-bound work while staying wire-compatible with Sidekiq.

## Layers

Each class has one reason to change.

| Layer | Owns |
|---|---|
| **Swarm** | Parent process; forks N children, PID supervision, rolling restart |
| **Manager** | Inside each child: thread pool, lifecycle, heartbeat |
| **Fetcher** | Reliable `BLMOVE` fetch: main queue → per-process private list |
| **Processor** | Pops the private list, runs the middleware chain, invokes `perform` |
| **Client** | Enqueue, Lua bulk path, Redis-outage local buffer |
| **Middleware** | Client + server chains (the Sidekiq contract) |
| **Web** | Rack app serving the precompiled SolidJS SPA + JSON APIs |
| **RedisPool** | Per-process pool over redis-client |

The default fetcher is **reliable**: an atomic `BLMOVE` moves a job from the main queue to a per-process private list, so a `SIGKILL`'d worker never loses in-flight jobs — they're reclaimed on the next boot.

## Boot ordering

1. Host app boots fully; initializers run; eager-loaded constants resolve.
2. The railtie's `after_initialize` hook fires.
3. The swarm closes parent-side connections that must not survive a fork (DB, Redis).
4. The swarm forks N children.
5. Each child reconnects its DB and opens a fresh Redis pool, then starts fetching.
6. The parent enters its supervision loop.

This is why **a Redis socket is never shared across a fork** — parent sockets are closed before forking and reopened inside each child.

## Signals

| Signal | Target | Effect |
|---|---|---|
| `SIGTERM` / `SIGINT` | parent | Graceful drain; relayed to children; in-flight finishes to `shutdown_timeout`, then exit |
| `SIGTSTP` | parent | Quiet globally: relayed to children, each stops fetching; in-flight continues. **One-way — there is no resume**; send `SIGTERM` to shut down |
| `SIGUSR1` | parent | Rolling restart: fork a replacement, wait for heartbeat, `SIGTERM` the old slot, repeat |
| `SIGUSR2` | child | Reopen log files (logrotate) |
| `SIGKILL` | any | Safe — private-list entries stay in Redis and are reclaimed on next boot |

## Platforms

Ruby `>= 3.2.0`, Redis `>= 7.0.0`. JRuby, TruffleRuby, and Windows fall back to threads-only mode (no fork), behaviorally equivalent to stock Sidekiq.
