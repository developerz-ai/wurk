# Deploying Wurk

Wurk is a drop-in for Sidekiq, so it deploys the same way: a long-running worker
process supervised by your init system, signalled for quiet/reload/stop during a
deploy. If you already run Sidekiq under systemd or capistrano-sidekiq, the only
change is the binary name (`sidekiq` → `wurk`) — the signals, flags, and config
file are identical.

> Authoritative signal reference: [`docs/target/sidekiq-free.md`](target/sidekiq-free.md) §21 (CLI).
> Just getting a worker running (incl. standalone, no Rails)? See [`docs/running.md`](running.md).
> Migrating an existing app? Start with [`docs/migrate-from-sidekiq.md`](migrate-from-sidekiq.md).
> Supplying the secrets a deploy needs (`REDIS_URL` with a password, the encryption key, dashboard credentials, the Sentry DSN)? See [`docs/secrets.md`](secrets.md).

---

## The runner

| Binary | What it does | Sidekiq equivalent |
|---|---|---|
| `bundle exec wurk` | Single worker process, thread pool | `sidekiq` |
| `bundle exec wurkswarm` | Forks N worker children from one preloaded parent (real parallelism) | `sidekiqswarm` |

`sidekiqswarm` ships as an alias for `wurkswarm`, so an existing Enterprise
`sidekiqswarm` invocation keeps working unchanged.

In a Rails app the engine auto-starts the swarm during boot, so your web/worker
dynos often need no separate worker command at all — set `WURK_DISABLED=1` on
processes that should *not* fork workers (e.g. the web process). The standalone
runners below are for non-Rails apps, or when you want the worker in its own unit.

Common flags (same as Sidekiq): `-c` concurrency, `-q queue[,weight]`, `-r` require
path, `-t` shutdown timeout (seconds), `-e` environment, `-C` config YAML. With no
`-C`, Wurk auto-discovers `config/wurk.yml` then `config/sidekiq.yml` (`.erb` ok).

---

## Signals

These are what your deploy tooling sends. Wurk implements the full Sidekiq set.

| Signal | Send to | Effect |
|---|---|---|
| `TERM` / `INT` | `wurk`, swarm parent | Graceful shutdown — stop fetching, let in-flight jobs finish up to the shutdown timeout (`-t`, default **25s**), then exit. The swarm parent relays `TERM` to every child and waits `timeout + 5s` before `KILL`ing stragglers. |
| `TSTP` | `wurk`, swarm parent | Quiet — stop fetching new work; in-flight jobs finish. **One-way: there is no resume.** Quiet, then `TERM` to shut down. |
| `USR1` | swarm parent **only** | Zero-downtime rolling restart — fork a replacement child, wait for its heartbeat, `TERM` the old one, then the next slot. See [§ Rolling restarts](#rolling-restarts). |
| `TTIN` / `INFO` | `wurk` only | Dump every thread's backtrace to the log (for diagnosing a stuck worker). |
| `USR2` | `wurk`, swarm parent | Reopen log files (logrotate). The swarm parent relays it to every child. |

Two sharp edges, both provable from the trap tables (`Wurk::CLI::SIGNAL_HANDLERS`,
`Wurk::Swarm::SWARM_SIGNALS`, `Wurk::Swarm::ChildBoot::CHILD_SIGNALS`):

- **Don't send `USR1` to a plain `wurk` process.** The single-process CLI traps
  `INT TERM TSTP TTIN INFO USR2` and nothing else, so `USR1` hits its default
  disposition and terminates the process abruptly, mid-job. Rolling restart is a
  swarm-parent feature. (Swarm *children* trap `USR1` as an explicit no-op, so a
  stray signal to a child pid is harmless.)
- **`TTIN` / `INFO` are single-process only.** The swarm parent and its children do
  not trap them, so use them against `bundle exec wurk`, not `wurkswarm`.

**Quiet is global and sticky.** `TSTP` on the swarm parent sets a flag that is relayed
to every live child *and* inherited by every future fork — a child that crashes or is
memory-recycled while the swarm is quiet boots already quieted, so nothing resumes
fetching behind your back during maintenance.

The standard deploy dance is **quiet, then stop**: send `TSTP` early in the deploy so
the old worker stops claiming new jobs, then `TERM` once the new release is live. A
`SIGKILL` at any point is safe — reliable fetch keeps in-flight jobs on a per-process
private list in Redis, and they're reclaimed on the next boot (each booting worker runs
an orphan sweep immediately, plus a locked cluster sweep every 60s).

---

## Rolling restarts

`SIGUSR1` to a **swarm parent** cycles every child onto new code without dropping a
job and without a window where the fleet is empty. The parent runs a non-blocking
state machine (`Wurk::Swarm::Restart`), advancing **one slot at a time**, one phase per
0.2s supervise tick:

```text
spawn replacement  →  await its first heartbeat  →  TERM the old child
                   →  await the old child's exit  →  next slot
```

| Phase | Bounded by | What happens on timeout |
|---|---|---|
| `await_heartbeat` | `HEARTBEAT_WAIT` = **30s** | Logs a warning and proceeds to `TERM` the old child anyway. |
| `await_exit` | shutdown timeout **+ 5s** (`SHUTDOWN_GRACE`) | `KILL`s the old child once, then waits for the reaper to confirm the exit. |

The replacement is a fresh fork of the **parent's** already-loaded application, so a
rolling restart picks up new code only if the parent itself is running the new release
— i.e. `USR1` is for reloading *state* (leaked memory, stale connections) in a
long-lived parent. **To deploy new code you must restart the parent process** (new
release directory, new container image, `systemctl restart`). This is the same
constraint `sidekiqswarm` has.

**Guarantees and costs:**

- **No fetch gap.** The old child keeps fetching until its replacement has written a
  heartbeat to Redis, so the slot is never unstaffed.
- **No dropped jobs.** The old child gets a normal `TERM` drain; anything it doesn't
  finish stays on its private list and is reclaimed.
- **Duration ≈ N × (child boot + drain).** One slot is in flight at a time, so a
  16-child swarm takes 16 sequential cycles. Worst case per slot is 30s (heartbeat
  wait) + shutdown timeout + 5s.
- **`TERM` always wins.** The state machine advances one phase per tick and never
  sleeps, so a shutdown lands within a tick regardless of restart state; `TERM` aborts
  the restart and drains the replacement and the old child as ordinary children.
- **Failed replacements don't cost you the slot.** If a replacement dies before it
  heartbeats, the old child is *kept*, a per-slot exponential backoff is applied
  (1s → 2s → 4s …, capped at 30s), and the slot is retried. A crash-looping new
  release degrades to "old workers keep running", not "no workers".

**Use `USR1` when** the parent is healthy and you want to recycle children (memory
growth, connection churn). **Use a full parent restart when** you are shipping new
code, changing `WURK_COUNT`/topology, or changing anything read at parent boot.

> ⚠️ **Not available on the Rails auto-boot swarm.** When the railtie boots the swarm
> inside your Rails process it calls `swarm.boot(install_signals: false)` — the host
> app owns the process signals, so no `USR1` handler is installed and `USR1` would hit
> the *host's* disposition. Rolling restart is for `wurkswarm` (or a swarm you boot
> yourself with `install_signals: true`).

---

## Memory-based auto-restart

Ruby worker processes leak. The swarm parent can recycle a child that grows past an
RSS ceiling.

| Knob | Value |
|---|---|
| `SIDEKIQ_MAXMEM_MB` | Drop-in name (Sidekiq Enterprise). |
| `WURK_MAXMEM_MB` | Native alias. Takes precedence over `SIDEKIQ_MAXMEM_MB`. |
| `config.memory_limit_mb = 1024` | Ruby setter. An explicit value wins over both env vars. |
| Default | **Disabled.** `nil`, `0`, empty, or unparseable input disables recycling (it never raises at boot). |

```bash
SIDEKIQ_MAXMEM_MB=1500 bundle exec wurkswarm -e production
```

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.memory_limit_mb = 1500
end
```

**How it's measured.** Every **10s** (`MEMORY_CHECK_INTERVAL`) the parent reads
`/proc/<pid>/statm` for each child and converts the resident-pages field to KB
(pages × 4KB). No gem, no `ps` fork. On a platform without `/proc` the read returns
`nil` and the child is simply never recycled — **memory recycling is Linux-only in
practice**.

**What happens on breach.** The child is handed to the *same* rolling-restart state
machine described above: replacement forked → heartbeat awaited → old child `TERM`ed
and drained. So a recycle is graceful, never drops a job, and can't overlap a rolling
restart already in flight on that slot (the queue de-duplicates by pid). The parent
logs:

```text
swarm: child 4242 RSS 1574912KB >= 1536000KB; recycling
```

> **Divergence from Sidekiq Enterprise.** The Ent spec
> ([`docs/target/sidekiq-ent.md`](target/sidekiq-ent.md) §7.5) describes signalling
> the bloated child with `USR2` first. Wurk does not — `USR2` is reserved for log
> reopening, and the graceful replacement-then-`TERM` path already gives a cleaner
> hand-off. The observable contract (child exceeding the threshold is gracefully
> replaced) is the same.

---

## Leader election

Every worker process campaigns for one cluster-wide lock so that fleet-wide periodic
work happens exactly once, not once per process.

| Detail | Value |
|---|---|
| Redis key | `dear-leader` (STRING) holding `<hostname>:<pid>:<nonce>` |
| Acquisition | `SET NX EX`, TTL **30s** |
| Renewal | every **15s** while leader |
| Follower re-check | every **60s** |
| Fencing token | `INCR leader-token` on every follower→leader transition, exposed as `Leader#token` |
| Opt out | `WURK_LEADER=false` (or `SIDEKIQ_LEADER=false`) — the process never campaigns |
| Hook | `config.on(:leader) { … }` fires when this process gains leadership |

Leader-gated work — every process runs the loop, but only the leader acts:

- **Periodic (cron) jobs** — only the leader enqueues per tick.
- **Metrics rollup** and the **per-queue gauge sampler** that feed the dashboard's
  historical charts.
- **Historical metrics snapshots** (when `config.retain_history` is set).

Explicitly *not* leader-gated: the **scheduled/retry poller** and the **reliable-fetch
orphan reaper**. The reaper uses its own `SET NX EX` lock so it keeps sweeping even if
the leader is dead.

**What this means for a deploy:**

- Leadership is best-effort, not Raft. A partitioned ex-leader can briefly co-exist
  with a new one until the 30s TTL expires. Idempotency-guard anything in an
  `on(:leader)` hook; use the fencing token if you need a monotonic guard.
- A **graceful** shutdown CAS-releases the lock (only if we still own it), so a
  follower promotes immediately instead of waiting out the TTL. A `SIGKILL`ed leader
  costs the cluster up to **30s** of no leader — one missed cron minute is possible.
- **`TSTP` does not stand a leader down.** Quiet stops *fetching*; the cron poller is
  deliberately left running, so a quieted leader keeps enqueueing periodic jobs. Only
  a full shutdown stops it. Quiet the fleet, don't expect cron to pause.
- Use `WURK_LEADER=false` on hot-standby or canary pools that must never own cron.

---

## systemd

A ready-to-edit unit ships at [`examples/wurk.service`](../examples/wurk.service).
Copy it, adjust the paths/user, and install:

```bash
sudo cp examples/wurk.service /etc/systemd/system/wurk.service
sudo systemctl daemon-reload
sudo systemctl enable --now wurk
```

Then:

```bash
sudo systemctl reload wurk    # SIGTSTP — quiet (stop fetching, finish in-flight)
sudo systemctl stop wurk      # SIGTERM — graceful drain up to the shutdown timeout
sudo systemctl restart wurk   # quiet+stop+start
journalctl -u wurk -f         # tail logs
```

Two details that differ from a stock Sidekiq unit:

- **`Type=simple`, not `Type=notify`.** Wurk does not emit `sd_notify` readiness or
  watchdog pings, so there's no `WatchdogSec`. systemd considers the process ready as
  soon as `ExecStart` forks.
- **`TimeoutStopSec` ≥ shutdown timeout.** The unit sets `TimeoutStopSec=30` against
  the default 25s drain so a clean shutdown always wins before systemd's `SIGKILL`.
  If you raise `-t`, raise `TimeoutStopSec` to match.

### Multiple workers

Run several workers on one host with a template unit. Save the example as
`/etc/systemd/system/wurk@.service` and start instances:

```bash
sudo systemctl enable --now wurk@1 wurk@2 wurk@3
```

Or run one `wurkswarm` unit instead, which forks children itself — change
`ExecStart` to `bundle exec wurkswarm -e production` and
`ExecReload=/bin/kill -USR1 $MAINPID` (rolling restart instead of plain quiet).

---

## capistrano-sidekiq

[`capistrano-sidekiq`](https://github.com/seuros/capistrano-sidekiq) shells out to
the runner and sends the signals above for quiet/restart/stop. The signal handling is
fully drop-in:

- `Sidekiq::CLI` is aliased to `Wurk::CLI`, and
- the `TSTP` / `TERM` / `USR1` signal semantics match exactly.

The one thing to map is the binary name. Wurk ships `wurk`, `wurkswarm`, and a
`sidekiqswarm` alias — but there is **no `sidekiq` binary** (see
[`docs/migrate-from-sidekiq.md`](migrate-from-sidekiq.md)). So an Enterprise
`sidekiqswarm` invocation drops in unchanged, while a `bundle exec sidekiq` invocation
needs pointing at `wurk`: set `sidekiq_role`/`sidekiq_command` config to
`wurk`/`wurkswarm`, or add a tiny `bin/sidekiq` shim that `exec`s `wurk`. The systemd
integration mode drops in the same way — replace the generated unit's `ExecStart` with
`bundle exec wurk` and keep the rest.

---

## Heroku / Procfile

```procfile
worker: bundle exec wurkswarm -e production
```

Use `wurkswarm` for fork-based parallelism inside the dyno (set `WURK_COUNT` to the
dyno's core count), or `bundle exec wurk` for a single process if you'd rather scale
out by adding worker dynos. Heroku sends `SIGTERM` on dyno cycle, which triggers
Wurk's graceful drain — set the shutdown timeout (`-t`) below Heroku's 30s kill window
so jobs finish cleanly.

---

## Docker

The repo's own [`Dockerfile`](../Dockerfile) (which builds the public demo image) is a
usable template for a worker image. The shape that matters:

```dockerfile
# Dockerfile
# Stage 1 — build the dashboard SPA. Only needed if you build Wurk from source;
# consumers installing the gem get the precompiled bundle in vendor/assets.
FROM oven/bun:1.3.14-slim AS spa
WORKDIR /src
COPY frontend/package.json frontend/bun.lock ./frontend/
RUN cd frontend && bun install --frozen-lockfile
COPY frontend/ ./frontend/
RUN cd frontend && bun run build

# Stage 2 — Ruby runtime. No Node/bun at runtime.
FROM ruby:3.4-slim-bookworm
ENV RAILS_ENV=production
RUN useradd --create-home --shell /bin/bash wurk
WORKDIR /app
COPY . /app
RUN bundle install --jobs 4 --retry 3 && chown -R wurk:wurk /app
USER wurk
EXPOSE 3000 7433          # 3000 = your web app, 7433 = Wurk health probes
ENTRYPOINT ["/app/bin/entrypoint"]
CMD ["web"]
```

**One image, two roles.** The demo entrypoint switches on its argument — `web` runs
Puma with `WURK_DISABLED=1` (so the web container never forks workers), `worker` runs
the swarm. Copy that pattern rather than building two images:

```bash
# bin/entrypoint
case "${1:-web}" in
  web)
    export WURK_DISABLED=1
    exec bundle exec rails server -b 0.0.0.0 -p "${PORT:-3000}"
    ;;
  worker)
    exec bundle exec wurkswarm -e production
    ;;
esac
```

### PID 1 and signals

This is the one thing containers get wrong, and it silently costs you the graceful
drain.

- **`exec`, always.** `exec bundle exec wurkswarm` makes the swarm parent PID 1 so it
  receives `SIGTERM` directly. A shell wrapper that *doesn't* `exec` keeps the shell as
  PID 1, and the shell will not forward `TERM` to the swarm — Docker's grace period
  elapses and everything gets `SIGKILL`ed mid-job.
- **Prefer exec-form `ENTRYPOINT`/`CMD`** (`["bundle", "exec", "wurkswarm"]`). Shell
  form (`ENTRYPOINT bundle exec wurkswarm`) wraps the command in `/bin/sh -c`, which
  reintroduces the same problem.
- **PID 1 has no default signal dispositions**, but Wurk installs explicit traps for
  everything it cares about (`TERM INT TSTP USR1 USR2` on the swarm parent), so it
  works as PID 1 without an init shim. You still may want `--init` / `tini` so the
  reaping of *your app's* stray grandchildren isn't the swarm's problem — the swarm
  reaps only its own children.
- **`docker stop` grace must exceed the drain.** `docker stop` sends `TERM` then
  `KILL` after 10s by default; the swarm waits `shutdown_timeout + 5s` (default 30s)
  for its children. Use `docker stop -t 40` / `stopGracePeriod: 40s`.
- **Redis must be reachable at boot.** Each forked child `PING`s its fresh pool and
  crashes (to be respawned with backoff) if it can't reach Redis, so a container
  started before Redis is up will crash-loop its children rather than silently idle.

---

## Kubernetes

### Health probes

Wurk ships a dependency-free HTTP listener for probes — a raw `TCPServer` and one
accept thread, no Rack — so it works in a swarm child, the standalone CLI, or embedded
mode alike. It is **opt-in**:

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.health_check(port: 7433)               # bind: "0.0.0.0", ready_window: 30
end
```

| Method + path | 200 when | 503 when |
|---|---|---|
| `GET /live` | The launcher is running. | The launcher is stopping — i.e. after `quiet` (`TSTP`) or `stop` (`TERM`). Body: `{"status":"down","check":"live","reason":"stopping"}` |
| `GET /ready` | Redis answers `PING` **and** the heartbeat fired within `ready_window` (default **30s**). | Either check fails. Body carries `"reason":"redis unreachable"` or `"reason":"heartbeat stale"`. |

Anything else returns `404` JSON; any non-`GET` returns `405`. All responses are
`Content-Type: application/json` with `Connection: close`.

Knobs (`Wurk::Configuration#health_check`): `port:` (required, 0–65535 — `0` lets the
kernel pick), `bind:` (default `"0.0.0.0"`), `ready_window:` (default `30`, must be
> 0). The listener starts **last** in the launcher's boot order, so probes are not
accepted until pollers, managers, and the reaper are up.

> **Swarm mode: the port is shared, and it fails over.** All children try to bind the
> same port; the first wins and the rest poll every **5s** to take it over. When the
> owning child exits (crash-respawn, rolling restart, memory recycle) a survivor picks
> the port up within ~5s, so probes ride out ordinary child churn instead of going
> dark. Probes therefore report *a* child in the pod, not every child.

> ⚠️ **`/live` goes 503 on quiet.** `TSTP` sets `stopping?`. If `/live` is wired to
> `livenessProbe`, quieting a pod makes the kubelet restart it. That's usually what you
> want during a rolling update (quiet happens inside `preStop`, right before the pod
> dies anyway) but never quiet a pod you intend to keep.

### Deployment manifest

```yaml
# k8s/worker-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wurk-worker
spec:
  replicas: 3
  selector:
    matchLabels: { app: wurk-worker }
  template:
    metadata:
      labels: { app: wurk-worker }
    spec:
      # shutdown_timeout (25s) + the swarm's 5s grace + slack for the preStop sleep.
      terminationGracePeriodSeconds: 60
      containers:
        - name: worker
          image: registry.example.com/myapp:1.4.2
          args: ["worker"]
          env:
            - name: RAILS_ENV
              value: production
            - name: WURK_COUNT          # forked children per pod
              value: "4"
            - name: SIDEKIQ_MAXMEM_MB   # graceful child recycle above 1.5GB RSS
              value: "1500"
            - name: REDIS_URL          # secret when it embeds a password — see secrets.md
              valueFrom:
                secretKeyRef: { name: wurk, key: redis-url }
          ports:
            - name: health
              containerPort: 7433
          # Give a cold Ruby boot up to 60 × 2s before liveness starts judging.
          startupProbe:
            httpGet: { path: /live, port: health }
            periodSeconds: 2
            failureThreshold: 30
          livenessProbe:
            httpGet: { path: /live, port: health }
            periodSeconds: 10
            failureThreshold: 3
          # Readiness gates on Redis + a fresh heartbeat. Heartbeats are written
          # every 10s, and the default ready_window is 30s, so periodSeconds must
          # stay comfortably above the beat interval.
          readinessProbe:
            httpGet: { path: /ready, port: health }
            periodSeconds: 15
            failureThreshold: 2
          lifecycle:
            preStop:
              exec:
                # Quiet first so the pod stops claiming new jobs, then let the
                # TERM that follows drain what is already in flight.
                command: ["/bin/sh", "-c", "kill -TSTP 1 && sleep 5"]
          resources:
            requests: { cpu: "2", memory: 2Gi }
            limits:   { memory: 3Gi }
```

**`terminationGracePeriodSeconds` vs `shutdown_timeout`.** The kubelet runs `preStop`,
sends `TERM`, then `SIGKILL`s the pod once the grace period elapses — the clock starts
at the *beginning* of `preStop`. Budget:

```text
terminationGracePeriodSeconds  >  preStop duration
                                  + shutdown_timeout (-t, default 25s)
                                  + 5s   (the swarm's SHUTDOWN_GRACE before it KILLs children)
```

With the defaults that's 5 + 25 + 5 = 35s, so 60s leaves real headroom. If you raise
`-t`, raise the grace period with it. Getting this wrong isn't data loss — a `SIGKILL`ed
worker's in-flight jobs stay on its private list and are reclaimed on the next boot —
but it does mean retries and duplicate work you didn't need.

**Set memory `limits` above `SIDEKIQ_MAXMEM_MB × WURK_COUNT` plus the parent's
footprint.** The recycle threshold is per child; the cgroup limit is per pod. If the
cgroup OOM-kills first you get a hard `SIGKILL` instead of the graceful replace.

**Rolling updates ship new code by replacing pods, not by `USR1`.** Kubernetes already
gives you the zero-downtime property that rolling restart gives a long-lived swarm
parent — leave `maxUnavailable` at its default and let the new ReplicaSet come up
`Ready` (i.e. Redis-reachable and heartbeating) before the old pods drain.

---

## Capacity and sizing

Two independent knobs, and the total is their product. Full treatment, including the
DB-pool math, is in
[`docs/migrate-from-sidekiq.md` §2](migrate-from-sidekiq.md#2-concurrency-vs-parallelism-read-this) —
the deploy-time summary:

| Knob | Controls | How to set it | Default |
|---|---|---|---|
| **Parallelism** | Forked worker **processes** per host/pod | `WURK_COUNT` env var (`SIDEKIQ_COUNT` alias) | CPU core count (`Etc.nprocessors`) |
| **Concurrency** | **Threads** per process | `config.concurrency`, `-c`, YAML `:concurrency`, or `RAILS_MAX_THREADS` | `5` |

```text
in-flight jobs per host = WURK_COUNT × concurrency
DB connections per host = WURK_COUNT × pool     (each fork opens its own pool)
```

- A whole-number `WURK_COUNT` is an absolute process count; a fractional value is a CPU
  multiplier (`WURK_COUNT=0.5` → half the cores, rounded). The result is floored at 1,
  and unparseable input falls back to the core count.
- **`WURK_COUNT` only applies to the forking runners** — `wurkswarm` and the Rails
  engine's auto-boot swarm. Plain `bundle exec wurk` is a single process and ignores
  it. There is no `WURK_CONCURRENCY` env var.
- **The default is aggressive on a big box.** 16 cores × 5 threads = 80 in-flight jobs
  and 80 DB connections from one host. Pin `WURK_COUNT` explicitly in production
  rather than inheriting the core count from whatever instance type you land on —
  especially in containers, where `nprocessors` may report the *node's* cores, not your
  CPU limit.
- Size each process's DB pool to cover `concurrency`, then check
  `WURK_COUNT × pool ≤ your database's spare connections`.
- Rule of thumb: `concurrency: 5` and `WURK_COUNT` = cores you want to dedicate to
  jobs. Raise concurrency for IO-bound work, raise `WURK_COUNT` for CPU-bound work,
  re-check the connection and memory math after either change.

---

## Zero-downtime deploy checklist

The whole page in the order you'd actually execute it. Steps 3–5 differ by platform;
everything else is the same everywhere.

1. **Ship the new release** alongside the old one (new release dir, new image tag) —
   don't touch the running workers yet.
2. **Quiet the old workers.** `TSTP` to the swarm parent (or `systemctl reload wurk`,
   or a `preStop` hook). They stop claiming new jobs; in-flight work continues. Quiet
   is one-way and sticky — the only way forward is `TERM`.
3. **Wait out the long tail.** Give the drain roughly your longest job's runtime, or
   watch the Busy count on the dashboard hit zero. This is the step people skip.
4. **Start the new workers**, pointing at the new release. Under Kubernetes the new
   ReplicaSet's `readinessProbe` (`/ready`) does this for you: a pod is Ready only when
   Redis answers and it has heartbeated within `ready_window`.
5. **Stop the old workers.** `TERM`. In-flight jobs get up to `shutdown_timeout`
   (`-t`, default 25s); the swarm parent waits `timeout + 5s` before `KILL`ing
   stragglers. Anything killed anyway is reclaimed from its private list on the next
   boot, so the worst case is a retry, not a loss.
6. **Confirm the fleet.** The dashboard's Busy page should show only new-release
   processes; the swarm parent logs a line per respawn/restart.

Notes that decide *which* mechanism you use:

- **New code ⇒ restart the parent.** `USR1` re-forks children from the parent's
  already-loaded app, so it recycles memory and connections, not code.
- **Migrations first, backwards-compatible always.** Old and new workers overlap during
  steps 2–5, and job arguments enqueued by the old release will be dequeued by the new
  one (and vice versa). Deploy schema changes and argument-shape changes in two passes.
- **Sidekiq and Wurk can share one Redis during a cutover** — same key schema, same job
  JSON — so the same checklist works for the migration deploy itself.
- **Expect a leader handover** in step 5. A graceful shutdown releases `dear-leader`
  immediately; a `SIGKILL`ed leader costs up to 30s, during which cron does not fire.
