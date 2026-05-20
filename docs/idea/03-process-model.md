# Process Model

## Fork after boot

The host app boots first — Rails initializers run, autoload eager-loads classes, DB pool is created. Only then does Wurk fork. Children inherit memory via copy-on-write, so loaded gems and constants are shared read-only pages.

This is the same model as Sidekiq Enterprise's swarm, except it's built in and triggered automatically.

## Configuration knobs

- **workers** — number of forked processes
- **concurrency** — threads per process
- **queues** — ordered list of queue names to consume from
- **swarm topology** — optional advanced mode where each forked slot has its own queues and concurrency (Wurk extension on top of Ent's flat swarm)
- **memory_limit** — RSS threshold past which the parent gracefully recycles a child
- **shutdown_timeout** — seconds to let in-flight jobs finish on SIGTERM

## Boot ordering (must be exact)

1. Host app boots fully. Initializers run. Eager-loaded constants resolved.
2. Railtie `after_initialize` fires.
3. Swarm closes parent-side connections that should not survive fork (DB, Redis).
4. Swarm forks N children.
5. Each child reconnects DB and creates a fresh Redis pool, then starts fetching.
6. Parent enters its supervision loop.

Skipping step 3 leaves inherited sockets open in children — a classic post-fork bug. Skipping step 5 means children share a socket and corrupt each other's responses.

## Worker topology (Wurk extension)

Instead of a flat "N identical forks", users can declare specialized slots. Examples in concept:

- Two forks dedicated to the critical queue with low concurrency.
- Two forks dedicated to bulk + low-priority queues with high concurrency.

The benefit is queue isolation. A flood on the bulk queue doesn't starve critical-queue throughput, because critical-queue forks don't fetch from bulk.

## Supervision

The parent waits on child PIDs. If a child exits unexpectedly, the parent respawns it in the same slot with the same config. If a child exceeds the memory limit, the parent sends a graceful-restart signal — the child finishes in-flight jobs, exits, and the parent respawns.

## When forking is disabled

- Test environment: everything runs inline in the test process.
- Platforms without fork (JRuby, TruffleRuby, Windows): threads-only fallback, behaviorally equivalent to stock Sidekiq.
