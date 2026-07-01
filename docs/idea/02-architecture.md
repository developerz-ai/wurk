# Architecture

## Layers

| Layer | Role |
|---|---|
| Engine | Rails mountable engine. Owns the dashboard, registers the railtie, exposes the mount point |
| Railtie | Hooks into Rails boot to trigger the swarm after `after_initialize` |
| Swarm | Parent process. Forks N worker processes, monitors PIDs, relays signals, restarts crashed children, handles rolling restart |
| Manager | Inside each forked child. Owns the thread pool, the lifecycle, the heartbeat |
| Fetcher | BLMOVE-based reliable fetch from queue list → per-process private list |
| Processor | Pops from private list, runs middleware chain, invokes the user's perform |
| Client | Enqueue interface. Bulk enqueue via Lua. Redis-outage local buffer |
| Middleware | Server and client chains, same contract as Sidekiq |
| Web | Rack app mounted under the engine. Serves the SolidJS SPA (precompiled) and JSON APIs |
| RedisPool | Per-process connection pool using redis-client |

## Process tree at runtime

The parent process is the Rails server (embedded mode) or the standalone runner. Under it, the swarm parent supervises N forked worker children. Each child runs its own thread pool with C threads. Total real concurrency is workers × threads, with one GVL per child rather than one shared across all threads.

## Two run modes

- **Embedded.** Host app loads `wurk/rails`. Wurk forks workers as part of the host's boot lifecycle. One deploy, one process tree. The default for small-to-medium apps.
- **Standalone.** A separate worker deploy. Same code path, only the web server is skipped. The default for large apps that want worker scaling independent of web.

Both share the same code after the host app boots. The only difference is whether the host is Rails or a tiny standalone bootstrapper.

## Engine boundary

Anything user-facing (mount point, controllers, views, generators, asset path) lives inside the engine. Anything not user-facing (swarm, fetcher, processor, client, middleware) lives in plain Ruby under the gem's lib tree. This separation lets standalone mode skip the engine entirely.
