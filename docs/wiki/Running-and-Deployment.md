# Running and deployment

## Inside Rails, you start nothing

The engine's railtie boots the swarm during `after_initialize`, so a process that boots your app already has workers forking and fetching. Set `WURK_DISABLED=1` on any process that should *not*:

```bash
WURK_DISABLED=1 bundle exec rails server   # web only, no workers
bundle exec wurkswarm -e production        # the worker role
```

The Rails console and the test environment skip the auto-fork automatically.

## The two runners

| Binary | What it does | Sidekiq equivalent |
|---|---|---|
| `bundle exec wurk` | One process, one thread pool | `sidekiq` |
| `bundle exec wurkswarm` | Forks N children from one preloaded parent — real parallelism | `sidekiqswarm` |

`sidekiqswarm` is an alias for `wurkswarm`. There is **no `sidekiq` binary**; point any `bundle exec sidekiq` invocation at `wurk`. Flags are Sidekiq's: `-c`, `-q queue[,weight]`, `-r`, `-t`, `-e`, `-g`, `-C`, `-v`.

## Signals

| Signal | Effect |
|---|---|
| `TERM` / `INT` | Graceful drain; in-flight finishes within `shutdown_timeout`, then exit |
| `TSTP` | Quiet: stop fetching, finish in-flight. **One-way — there is no resume.** `TERM` to finish |
| `USR1` | Rolling restart of the swarm's children, one slot at a time |
| `USR2` | Child reopens log files (logrotate) |
| `KILL` | Safe — private-list entries stay in Redis and are reclaimed on next boot |

## `USR1` recycles memory, it does not deploy code

The replacement child is a fresh fork of **the parent's already-loaded application**, so a rolling restart picks up new code only if the parent is already running the new release. To ship code, restart the parent (new release dir, new image, `systemctl restart`). Same constraint as `sidekiqswarm`.

What `USR1` does guarantee: no fetch gap (the old child keeps fetching until its replacement heartbeats), no dropped jobs (normal `TERM` drain, remainder reclaimed), and a crash-looping replacement degrades to "old children keep running" — the slot is retried with exponential backoff rather than lost. Cost is sequential: N × (child boot + drain).

**`USR1` is not available on the Rails auto-boot swarm.** The railtie boots with `install_signals: false` because the host app owns process signals; rolling restart is for `wurkswarm`.

## Zero-downtime deploy

1. Ship the new release alongside the old — don't touch running workers yet.
2. `TSTP` the old swarm parent. It stops claiming; in-flight continues.
3. **Wait out the long tail** — roughly your longest job's runtime, or Busy hitting zero on the dashboard. This is the step people skip.
4. Start the new workers. Under Kubernetes the `readinessProbe` on `/ready` gates this for you — see [[Kubernetes Probes]].
5. `TERM` the old ones. In-flight gets `shutdown_timeout`; the parent waits `timeout + 5s` before `KILL`. Anything killed is reclaimed from its private list — worst case a retry, never a loss.
6. Confirm on the dashboard that Busy shows only new-release processes.

**Gotchas.** Old and new workers overlap during steps 2–5, so migrations and job-argument changes must ship backwards-compatible in two passes. Expect a leader handover at step 5 — a graceful shutdown releases the lock immediately, a `SIGKILL`ed leader costs up to 30s during which cron does not fire. And under a clustered Puma, Unicorn or Passenger, Wurk **refuses** to fork and logs why: give the swarm its own unit, or opt into embedded threads-only mode.

systemd units, capistrano, Procfiles, the Docker two-stage build and PID-1 signal handling, full k8s manifests, memory-based recycling, and capacity sizing: **[docs/deployment.md](https://github.com/developerz-ai/wurk/blob/main/docs/deployment.md)** and **[docs/running.md](https://github.com/developerz-ai/wurk/blob/main/docs/running.md)**.
