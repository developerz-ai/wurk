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

`wurkswarm` on a Rails target loads `config/application.rb` before the `WURK_PRELOAD` groups, so gems that need Rails at require time load. If that file raises `NameError`, because it uses a gem it expects the swarm to have preloaded, the process re-executes itself once (same pid, same environment) with the preload first, which is stock `sidekiqswarm`'s order, and logs a warning naming the first error. Such an app starts its boot twice, so a `Bundler.require` of your own in `config/application.rb` avoids that. An app needing both orders in one boot has no order that works: it fails, and shows both errors.

`sidekiqswarm` ships as an alias for `wurkswarm`, so an existing Enterprise
`sidekiqswarm` invocation keeps working unchanged.

In a Rails app the engine auto-starts the swarm during boot, so your web/worker
dynos often need no separate worker command at all — set `WURK_DISABLED=1` on
processes that should *not* fork workers (e.g. the web process). The standalone
runners below are for non-Rails apps, or when you want the worker in its own unit.

Common flags (same as Sidekiq): `-c` concurrency, `-q queue[,weight]`, `-r` require
path, `-t` shutdown timeout (seconds), `-e` environment, `-C` config YAML. With no
`-C`, Wurk auto-discovers `config/wurk.yml` then `config/sidekiq.yml` (`.erb` ok).

### Process titles

Every worker process titles itself the way stock Sidekiq does, program name
included, and rewrites the title on every heartbeat (10s):

```
sidekiq 8.1.5 myapp [3 of 10 busy]
sidekiq 8.1.5 myapp [0 of 10 busy] stopping
```

`8.1.5` is `Sidekiq::VERSION`, the upstream release Wurk is compatible with, not
the Wurk version; `myapp` is the tag (`-g`, default the directory name). A
`ps | grep '^sidekiq'` probe or runbook keeps working after the gem swap. The
Wurk version is in each process's heartbeat `info` hash (`version`). Code that appends a segment to `Sidekiq::Launcher::PROCTITLES`
still works. A worker embedded in a web server (`config.wurk.embed_in_web`,
`Wurk::Embedded`) leaves the server's title alone, as upstream does.

A `wurkswarm` parent titles itself after the binary that started it:
`wurkswarm myapp [3 of 3 processes]`, or `sidekiqswarm myapp [3 of 3 processes]`
when started as `sidekiqswarm`. A swarm the Rails engine starts inside a web
server leaves the server's title alone; its children are titled as above.

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
private list in Redis and are reclaimed once the owner's 60s heartbeat has expired, by
whichever worker sweeps next, about 90s after a pod restart and 90-140s for a host lost, at defaults on every supported server (about 1s for a swarm child). A restart does not shorten
that for a dead pod: the new process cannot tell a dead owner from a live one until the
heartbeat lapses.

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

Ruby worker processes leak. The swarm parent can recycle a child that grows past a
memory ceiling.

| Knob | Value |
|---|---|
| `SIDEKIQ_MAXMEM_MB` | Drop-in name (Sidekiq Enterprise). |
| `WURK_MAXMEM_MB` | Native alias. Takes precedence over `SIDEKIQ_MAXMEM_MB`. |
| `config.memory_limit_mb = 1024` | Ruby setter. An explicit value wins over both env vars. |
| Default | **Disabled.** `nil`, `0`, empty, or unparseable input disables recycling (it never raises at boot). |
| `WURK_MAXMEM_METRIC` / `config.memory_limit_metric =` | What the limit is compared against: `rss` (default, Enterprise's meaning), `pss` or `uss`. Wurk-only. An unknown value raises at boot. |

```bash
SIDEKIQ_MAXMEM_MB=1500 bundle exec wurkswarm -e production
```

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.memory_limit_mb = 1500
end
```

**How it's measured.** Every **10s** (`Swarm::MemoryWatch::CHECK_INTERVAL`) the parent
reads each child's memory from `/proc`. No gem, no `ps` fork.

| Metric | Source | Counts |
|---|---|---|
| `rss` | `/proc/<pid>/statm`, resident pages × the kernel's page size | Every resident page, including the ones still shared copy-on-write with the parent. Each child carries the whole preloaded app. |
| `pss` | `/proc/<pid>/smaps_rollup` `Pss` | Shared pages split across the processes sharing them. Sums to the real footprint of the fleet. |
| `uss` | `/proc/<pid>/smaps_rollup` `Private_Clean + Private_Dirty` | Only the child's own pages: what killing it would free. |

`rss` keeps Enterprise's trigger, so a limit carried over from Sidekiq Enterprise fires
at the same point. Its catch: RSS counts the preloaded app in every child, so it sits
well above what each child really costs, and it rises as copy-on-write pages get
written. `pss` or `uss` tracks the growth you actually want to cap. On a host without
`/proc` (macOS) or without `smaps_rollup` (Linux < 4.14), nothing is read and no child
is recycled; the parent logs a WARN at boot when a limit is set and it cannot read
the metric.

**What happens on breach.** The child is handed to the *same* rolling-restart state
machine described above: replacement forked → heartbeat awaited → old child `TERM`ed
and drained. So a recycle is graceful, never drops a job, and can't overlap a rolling
restart already in flight on that slot (the queue de-duplicates by pid). The parent
logs:

```text
swarm: child 4242 (slot 0) RSS 1574912KB >= 1536000KB 3605s after boot; recycling
```

**A limit below a fresh child is reported, not looped.** A child already over the limit
within its first 60s (`Swarm::MemoryWatch::FRESH`) is never recycled: its replacement
would boot just as large and be recycled in turn, forking a new child every few
seconds. That child is left running for its life, and the parent logs one ERROR per
slot:

```text
swarm: child 4242 (slot 0) is 812000KB RSS 1s after boot, already over memory_limit_mb (500 MB). ...
```

Raise the limit above what a booted child uses (or switch to `pss`). A child that
crosses the limit only after its first 60s is recycled as usual; if its replacement is
over within its own first 60s, the replacement is the one spared, so a slot recycles at
most once for that cause.

**Sizing the limit.** Read a booted child's memory after it has run real work (the
`pss` and `rss` columns of `bench/rss_soak.rb` show the shape; your app's numbers are
your own), then set the limit above that plus the growth you will tolerate. While a
recycle or rolling restart is in flight the slot runs **two** children, old and
replacement, so budget the pod for `WURK_COUNT + 1` children, plus the parent.

> **Divergence from Sidekiq Enterprise.** The Ent spec
> ([`docs/target/sidekiq-ent.md`](target/sidekiq-ent.md) §7.5) describes signalling
> the bloated child with `USR2` first. Wurk does not — `USR2` is reserved for log
> reopening, and the graceful replacement-then-`TERM` path already gives a cleaner
> hand-off. The observable contract (child exceeding the threshold is gracefully
> replaced) is the same. The fresh-child guard and the `pss`/`uss` metrics are
> Wurk-only.

## Memory

### Copy-on-write and the pre-fork warmup

A swarm child starts as a copy-on-write image of the parent: the app the parent loaded
costs memory once, until a child writes to a page and gets its own copy. Before its
first fork the swarm parent (both `wurkswarm` and the Rails auto-boot swarm) loads
what every child would otherwise load for itself and settles the heap:
`Process.warmup` on Ruby 3.3+, a full GC then `GC.compact` on Ruby 3.2.
`RUBY_DISABLE_WARMUP=1` skips the heap step. Respawns and recycles fork from the
running parent without it, because in a web process a full compaction is a pause its
requests would feel.

What it buys is the child's **shared ratio** right after boot,
`(Shared_Clean + Shared_Dirty) / Rss` from `smaps_rollup`. `bench/rss_soak.rb` prints it
at `jobs = 0`:

```bash
RSS_JOBS=0 ruby -Ilib bench/rss_soak.rb                         # with the warmup
RUBY_DISABLE_WARMUP=1 RSS_JOBS=0 ruby -Ilib bench/rss_soak.rb   # without
```

Measured 2026-11-11 on the `test/dummy` app (Ruby 3.4, 4 children, three runs each):
0.72 shared and 35 MB Pss per child with `Process.warmup`, 0.65 and 40 MB with the
Ruby 3.2 fallback (the same Ruby with `Process.warmup` removed), 0.57 and 46 MB with
no warmup. Measure your own app the same way; the ratio falls as jobs run and write to
inherited pages, which is the rest of the table in
[`benchmarks.md`](benchmarks.md#memory-per-process).

`WURK_PRELOAD_APP=1` / `SIDEKIQ_PRELOAD_APP=1` eager-loads the whole app in the parent
before the fork, so classes a child would autoload are shared instead of loaded N
times.

### Allocator

Each child runs `concurrency` threads, and glibc's malloc gives threads their own
arenas, which fragment: a multi-threaded Ruby process can hold far more RSS than its
live heap. Two common fixes, both set in the environment the parent starts in (the
children inherit it):

```dockerfile
# Option A: jemalloc
RUN apt-get update && apt-get install -y --no-install-recommends libjemalloc2
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2

# Option B: cap glibc's arenas
ENV MALLOC_ARENA_MAX=2
```

Which one wins depends on the app; measure before and after with the same bench, on
the same host:

```bash
RSS_JOBS=100000 ruby -Ilib bench/rss_soak.rb
MALLOC_ARENA_MAX=2 RSS_JOBS=100000 ruby -Ilib bench/rss_soak.rb
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 RSS_JOBS=100000 ruby -Ilib bench/rss_soak.rb
```

Compare the `steady` Pss slope per 10k jobs and the Pss at the last checkpoint. The
allocator changes where `MAXMEM` trips: re-size the limit after switching.

### Redis memory: Wurk-only keys

Beyond Sidekiq's own keys (queues, `schedule`, `retry`, `dead`, `processes`, stats),
these are the key families Wurk writes, when each goes away, and how to stop writing
it. None is written unless its feature is in use.

| Keys | Written by | Expires | Turn off |
|---|---|---|---|
| `status:<jid>` | Status tracking, per opted-in job | 30 min after the last write; `status_retention` changes what is kept after the job ends | Don't opt the class into status |
| `it-<jid>` | Iterable jobs (Sidekiq's schema) | Deleted on completion; 30 days otherwise | — |
| `unique:<digest>` | `unique!` + `unique_for:` | `unique_for` (+ the delay when scheduled); released on success or start | `unique_for: false` |
| `debounce:<digest>` | Debounce | When the pending job is due, plus a grace | Drop the debounce option |
| `throttle:<digest>:<slot>` | Throttle | End of its slot | Drop the throttle option |
| `lmtr-*` | Limiters | 90 days idle by default (`ttl:`, floored at 1 day); the `lmtr-list` index has no TTL | Don't build the limiter |
| `queue_slot:<queue>` | Global per-queue concurrency | No TTL; holders expire inside the ZSET and the next claim prunes them | Remove the queue cap |
| `b-<bid>*`, `batches` | Batches | 30 days; 24 h after `:success` | — |
| `flow:<fid>*`, `flows` | Flows | Batch clock (30 days) | — |
| `j\|*` | Per-class execution metrics | Minute buckets 8 h, 10-minute buckets 30 days; histograms 8 h | Metrics history off |
| `qm\|*` | Per-queue gauges (leader only) | 1-minute 24 h, 5-minute 7 days, 1-hour 30 days | Metrics history off |
| `history:metrics` | Cluster snapshots (leader only) | Capped stream | History off |
| `idempotency:<digest>` | HTTP API `Idempotency-Key` | `api_idempotency_ttl` (1 h) | Don't send the header |
| `profiles`, `<token>-<jid>` | Profiler | 1 day | Don't profile |

A Redis or Dragonfly store holding jobs must stay below `maxmemory`; see
[Dragonfly](#dragonfly). To see what a feature mix costs per job on your workload, run
`bench/rss_soak.rb` with `RSS_FEATURES` (`plain,status,unique,limiter`): every
checkpoint prints Redis `used_memory` and `DBSIZE`.

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
FROM oven/bun:1.4.3-slim AS spa
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
mode alike. It is **opt-in**, from the manifest with no application change:

```yaml
env:
  - { name: WURK_HEALTH_PORT, value: "7433" }
```

or from code, which wins when both are set and is the only way to reach the other knobs:

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.health_check(port: 7433)               # bind: "0.0.0.0", ready_window: 30
end
```

Where an HTTP listener does not fit, use the exec-style probe:

```yaml
# Before a worker's first heartbeat the probe would fail, so boot gets its own budget.
startupProbe:
  exec:
    command: ["bundle", "exec", "wurk", "health", "--window", "60"]
  periodSeconds: 10
  timeoutSeconds: 10
  failureThreshold: 30
livenessProbe:
  exec:
    command: ["bundle", "exec", "wurk", "health", "--window", "60"]
  periodSeconds: 30
  # Keep this generous. It has to cover `bundle exec` plus the probe's Redis timeouts;
  # the default of 1s fails on an outage, and restarts the very pods the probe spares.
  timeoutSeconds: 10
  failureThreshold: 3
```

`wurk health` boots no application. It exits 0 when a process on this host has a heartbeat
within `--window` seconds (default 60), `--min COUNT` raises how many must be beating, and it
passes when Redis cannot be read, so a store outage does not restart your workers, unless you
add `--strict`.

Prefer either to a `ps | grep` exec probe ([process titles](#process-titles)). That probe passes as long as the swarm parent
is alive, including while every child crash-loops and nothing is being processed. `wurkswarm`
itself gives up too: when every child has been crashing for `swarm_crash_exit_after` seconds
(default 600), it exits 1, so restartPolicy and CrashLoopBackOff can see the failure.

| Method + path | 200 when | 503 when |
|---|---|---|
| `GET /live` | The launcher is running. | The launcher is shutting down, i.e. after `stop` (`TERM`). A quiet process (`TSTP`) stays 200: it is alive. Body: `{"status":"down","check":"live","reason":"stopping"}` |
| `GET /ready` | Redis answers `PING` **and** the heartbeat fired within `ready_window` (default **30s**). In a swarm: at least `min_ready` children have a heartbeat inside `ready_window` (see [Health and supervision](#health-and-supervision)). | Either check fails. Body carries `"reason":"redis unreachable"` or `"reason":"heartbeat stale"`. |
| `GET /metrics` | Prometheus text format 0.0.4, served by the same listener unless `health_check(..., metrics: false)`. | — |

Anything else returns `404` JSON; any non-`GET` returns `405`. Every response except
`/metrics` is `Content-Type: application/json`; all carry `Connection: close`.

Knobs (`Wurk::Configuration#health_check`): `port:` (required, 0–65535 — `0` lets the
kernel pick), `bind:` (default `"0.0.0.0"`), `ready_window:` (default `30`, must be
> 0). The listener starts **last** in the launcher's boot order, so probes are not
accepted until pollers, managers, and the reaper are up.

> **Swarm mode: the port is shared, and it fails over.** All children try to bind the
> same port; the first wins and the rest poll every **5s** to take it over. When the
> owning child exits (crash-respawn, rolling restart, memory recycle) a survivor picks
> the port up within ~5s, so probes ride out ordinary child churn instead of going
> dark. Probes therefore report *a* child in the pod, not every child.

### Health and supervision

- **`/ready` counts the fleet.** In a swarm, `/ready` is 200 only when at least
  `min_ready` children have a heartbeat inside `ready_window`. The default is half the
  fleet, rounded up (`WURK_COUNT=4` → 2, `WURK_COUNT=5` → 3). Override it with
  `config.health_check(port: 7433, min_ready: N)`.
- **`/live` reflects only the port-owning child.** Keep it as the `livenessProbe`: a
  probe that restarted the pod whenever *any* child was slow would turn one stuck job
  into a pod restart. Unhealthy children are the parent's job (next point).
- **The parent replaces a child whose heartbeat stops moving.** If a child's heartbeat
  has not advanced for `swarm_heartbeat_timeout` seconds (default **60**, minimum
  **20**, `false` disables), the parent sends `TERM`, then `KILL` after
  `shutdown_timeout + 5s`, then respawns the slot as usual. A child that has never
  beaten gets 30s extra to boot. The check pauses while the swarm is quiet (`TSTP`),
  during a rolling restart or memory recycle, and while the parent itself can't reach
  Redis (so a Redis outage does not trigger a fleet-wide kill).
- **`GET /metrics`** serves Prometheus text format 0.0.4 on the probe port. Disable it
  with `health_check(..., metrics: false)`. Cluster-wide families are read from Redis
  and are **identical on every pod**: aggregate them with `max`, not `sum`, or a
  10-pod deployment reports 10× the backlog.

### Deployment manifest

Ready-to-adapt manifests live in
[`examples/kubernetes/`](../examples/kubernetes): this rolling fleet, the
[Recreate variant](#recreate-variant), the
[scrape config and alerts](#scraping-and-alerting).

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
            - name: WURK_HEALTH_PORT    # the listener every probe below reads
              value: "7433"
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
worker's in-flight jobs stay on its private list and are reclaimed once its heartbeat
expires — but it does mean retries and duplicate work you didn't need.

A host shutdown runs on a different budget. Where the kubelet's `shutdownGracePeriod` is set,
it caps a pod's grace during a node reboot however long `terminationGracePeriodSeconds` is. A job that needs longer will be killed there and
reclaimed, so anything that runs that long has to be safe to re-run.

**Set memory `limits` above `SIDEKIQ_MAXMEM_MB × WURK_COUNT` plus the parent's
footprint.** The recycle threshold is per child; the cgroup limit is per pod. If the
cgroup OOM-kills first you get a hard `SIGKILL` instead of the graceful replace.

**Rolling updates ship new code by replacing pods, not by `USR1`.** Kubernetes already
gives you the zero-downtime property that rolling restart gives a long-lived swarm
parent — leave `maxUnavailable` at its default and let the new ReplicaSet come up
`Ready` (i.e. Redis-reachable and heartbeating) before the old pods drain.

### Recreate variant

[`examples/kubernetes/worker-recreate.yaml`](../examples/kubernetes/worker-recreate.yaml):
one replica, `strategy: Recreate`. Pick it when:

- the fleet is one pod anyway, so there is nothing to roll;
- jobs are long, so a rolling overlap would run two generations for many minutes;
- a process must not overlap its successor, as with a schedule loaded by one pod only.

The cost is a processing gap of the drain plus the boot on every deploy. Queues keep
accepting jobs throughout, so this delays work and does not lose it. Two things follow:

- **Size the timeouts together.** `-t` for the longest job you will wait for, and
  `terminationGracePeriodSeconds` above `preStop + -t + 5s`. A 15-minute grace does nothing
  without a matching `-t`: the worker gives up at `-t` and requeues.
- **A PodDisruptionBudget of `minAvailable: 1` on one replica blocks every node drain.**
  Use `minAvailable: 0` or none.

### Scraping and alerting

[`examples/kubernetes/service-monitor.yaml`](../examples/kubernetes/service-monitor.yaml) has
the Service and ServiceMonitor, plus the NetworkPolicy ingress rule on 7433 that a
default-deny namespace needs. Without the rule the scrape target just reads as down.

[`examples/kubernetes/prometheus-rule.yaml`](../examples/kubernetes/prometheus-rule.yaml)
covers the exporter going away (`absent()`, without which every other alert goes quiet
along with it), Redis unreachable, missing children, queue latency, a queue nobody
consumes, no leader, dead-set growth, fetch errors and reclaims, using `wurk_leader`,
`wurk_fetch_errors_total`, `wurk_reaper_reclaimed_total` and `wurk_queue_consumers` among
others. Every metric and how to aggregate it is in
[metrics](metrics.md#7-exporting-to-an-external-system). A unit test keeps these manifests
in step with the exporter.

### Fiber servers

Falcon, or any web server running requests on a fiber scheduler, needs the Ruby driver on
the **client** side: `driver: :ruby`, which is redis-client's default. A C-level driver such
as `:hiredis` blocks the whole OS thread on each socket read and the fiber scheduler cannot
see it, so one slow Redis call freezes every request on that thread, for as long as the
socket timeout at worst. A forked worker is threaded, so `:hiredis` is fine there:

```ruby
Wurk.configure_client { |config| config.redis = { url: ENV["REDIS_URL"], driver: :ruby } }
Wurk.configure_server { |config| config.redis = { url: ENV["REDIS_URL"], driver: :hiredis } }
```

Do not embed the swarm in a fiber server's worker process. Run workers separately
(`WURK_DISABLED=1` on web) unless you have read
[running Wurk](running.md).

---

## Supported Redis backends

Wurk needs **one Redis-protocol server, version 7.0 or newer**, with
`maxmemory-policy noeviction` — the same requirement as Sidekiq. Any eviction policy
can silently delete queued jobs, and boot logs a warning for any other policy. The reaper
does not use `OBJECT`, so an LFU policy or a server without that command changes nothing:
reclaim latency is the same on all of them.

| Backend | Status | Notes |
|---|---|---|
| Redis 7.x | **Tested** — the whole suite, every PR | CI runs `redis:7.4`. |
| Valkey 8 | **Tested in CI** | The `topology` workflow runs the parity oracles and the core integration subset (push, reliable fetch, reaper, schedulers, swarm boot, rolling restart, batches, limiters, Lua) against `valkey/valkey:8`. |
| Redis Sentinel | **Tested in CI**, including a failover | `SENTINEL FAILOVER` while a fetcher is parked in `BLMOVE`: every job pushed before and after is fetched exactly once and both pools reconnect to the new primary. |
| TLS (`rediss://`) | **Tested in CI** | Self-signed CA via `ssl_params: { ca_file: }`; a server the CA didn't sign is refused. |
| ACL users | **Tested in CI** | `redis://user:pass@host` with `~* &* +@all -@dangerous +info` is enough: `INFO` (heartbeat, dashboard) is the only `@dangerous` command anywhere in `lib/`. |
| AWS ElastiCache (Redis OSS / Valkey), **cluster mode disabled** | Expected compatible, not tested against AWS | Use the primary endpoint. Set `maxmemory-policy` to `noeviction` in the parameter group — the default (`volatile-lru`) is wrong for a job queue. In-transit encryption is the TLS row (`rediss://`); RBAC/AUTH is the ACL row. A failover is a DNS flip: the pool redials on `READONLY` and on dropped connections. |
| ElastiCache **cluster mode enabled**, ElastiCache Serverless, Amazon MemoryDB | **Not supported** | All three speak the Cluster protocol (Serverless and MemoryDB always do, even with one shard), which rejects multi-key commands across hash slots — see Redis Cluster. |
| Dragonfly >= 1.34 | **Works in production; tested in CI** | The `compat` workflow leg runs the whole suite against v1.34.0 with stock Lua settings. Requirements and limits are [below](#dragonfly). |
| Redis Cluster | **Not supported** | `config.redis[:nodes]` raises at boot. Wurk, like Sidekiq, runs `MULTI` and multi-key Lua across a job's queue, the `queues` set, `schedule`/`retry`/`dead` and batch keys, which live in different hash slots. `RELIABLE_SCHEDULE_PROMOTE` also builds its target keys from payload data, which Cluster cannot route at all. |

### Dragonfly

Runs in production on 1.34, and the parity suite and a `kill -9` workload (reclaim, retries,
scheduled promotion, batches, limiters, cron leader, unique) also passed on 2.0. On a job
store, configure it like this:

- **Version >= 1.34.** Older releases reply differently to the `BITFIELD` the per-minute
  histograms use.
- **Keep a Dragonfly job store below `--maxmemory`, and alert well before it.** At the limit, an `LMOVE`/`BLMOVE` between shards can pop a job and drop the push, so the job runs with no private copy and is gone if the process dies or its retry is refused. Measured on 1.34 and 2.0.2: 2 of 16 lost. Redis and Valkey do not do this. See [reliability](reliability.md).
- **No `--cache_mode`.** That is eviction, and an evicted key is a lost job. Boot logs a
  warning when it sees it. At `--maxmemory` writes fail instead, as under Redis `noeviction`:
  enqueues raise, due scheduled jobs wait in their set, and in-flight work keeps draining.
- **`--proactor_threads` matching the CPU the pod actually gets.** Left unset it takes one
  thread per host core, and threads throttled by a lower CPU limit stall every client whose
  key they own. `--maxmemory` needs 256MiB per thread.
- **`--dbnum` covering your database number**, which only matters above the default 16.
- **Lua flags: none needed for Wurk.** The one script that derives a key from its payload
  carries its own grant, so stock Dragonfly runs `reliable_scheduler!`. Third-party Lua may
  still need `--default_lua_flags=allow-undeclared-keys`; sidekiq-unique-jobs, redlock and
  BullMQ are common cases. That flag serializes every script on the server. We measured a
  one-key `EVAL` at about a third of its stock throughput, so turn it on only when something
  requires it.

**Durability is the snapshot cadence.** There is no append-only log: a crash rewinds the
store to the last `--snapshot_cron`, so that interval is your RPO for every enqueued job, and
jobs finished since then run again. Run it often enough to match what losing that window
costs. SIGTERM writes a final snapshot first, so `terminationGracePeriodSeconds` must cover the
final save. We measured about 35 MB/s here, so 120s holds roughly 4 GB; re-measure with
`last_success_save_duration_sec` in `INFO persistence` and give the pod more grace as data
grows. A SIGKILL mid-save falls back to the previous snapshot.

Clients see `LOADING` while the data loads, as a plain `RedisClient::CommandError`. Workers log
it and retry. Gate the server's readiness on `INFO persistence` showing `loading:0`: its port
opens first. `--shard_round_robin_prefix` appears in older tuning guides, and current releases
list it as deprecated. Wurk doesn't require it.

### Wiring

Wiring each one through `config.redis` (the same hash Sidekiq takes):

```ruby
# TLS with a private CA
config.redis = { url: "rediss://redis.internal:6380/0", ssl_params: { ca_file: "/etc/ssl/redis-ca.pem" } }

# ACL user (or username:/password: keys)
config.redis = { url: "redis://wurk:#{ENV.fetch("REDIS_PASSWORD")}@redis.internal:6379/0" }

# Sentinel: `name:` is the master, as in Sidekiq
config.redis = {
  url: "redis://mymaster/0",
  name: "mymaster",
  sentinels: [{ host: "sentinel-1", port: 26379 }, { host: "sentinel-2", port: 26379 }],
  role: :master
  # sentinel_password: "…" when the sentinels themselves require AUTH
}
```

Two failover behaviours to know, both identical to Sidekiq:

- Redis replication is asynchronous. A job acknowledged by the old primary in the
  instant before a failover may not have reached the replica and is lost with it.
  `WAIT`-based durability is not something Sidekiq or Wurk do on push.
- `reconnect_attempts: 1` (the default) re-sends the one in-flight command on a fresh
  socket, so a reply lost mid-failover can apply that command twice — a duplicate
  push, at worst. See `RedisPool` for exactly which errors are replayed.

---

## Capacity and sizing

Two independent knobs, and the total is their product. Full treatment, including the
DB-pool math, is in
[`docs/migrate-from-sidekiq.md` §2](migrate-from-sidekiq.md#2-concurrency-vs-parallelism-read-this) —
the deploy-time summary:

| Knob | Controls | How to set it | Default |
|---|---|---|---|
| **Parallelism** | Forked worker **processes** per host/pod | `WURK_COUNT` env var (`SIDEKIQ_COUNT` alias) | `min(Etc.nprocessors, ceil(cgroup CPU quota / period))`, logged at boot |
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
  rather than inheriting the core count from whatever instance type you land on.
- **The default respects the container's CPU limit.** `nprocessors` reports the
  *node's* cores inside a container, so the default is capped by the cgroup quota
  (v2 `cpu.max`, v1 `cpu.cfs_quota_us` / `cpu.cfs_period_us`), rounded up and floored
  at 1: a pod with `limits.cpu: 2` on a 64-core node forks 2 children, not 64. No
  quota (`max`) means the core count. The chosen count and where it came from are
  logged at boot — check that line after the first deploy.
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
