# Deploying Wurk

Wurk is a drop-in for Sidekiq, so it deploys the same way: a long-running worker
process supervised by your init system, signalled for quiet/reload/stop during a
deploy. If you already run Sidekiq under systemd or capistrano-sidekiq, the only
change is the binary name (`sidekiq` → `wurk`) — the signals, flags, and config
file are identical.

> Authoritative signal reference: [`docs/target/sidekiq-free.md`](target/sidekiq-free.md) §21 (CLI).
> Migrating an existing app? Start with [`docs/migrate-from-sidekiq.md`](migrate-from-sidekiq.md).

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

| Signal | Effect |
|---|---|
| `TERM` / `INT` | Graceful shutdown — stop fetching, let in-flight jobs finish up to the shutdown timeout (`-t`, default **25s**), then exit. |
| `TSTP` | Quiet — stop fetching new work; in-flight jobs finish. Standalone has no resume (quiet, then stop); under `wurkswarm`, `CONT` resumes. |
| `USR1` | **`wurkswarm` only** — zero-downtime rolling restart: fork a replacement child, wait for its heartbeat, then `TERM` the old one, slot by slot. |
| `TTIN` / `INFO` | Dump every thread's backtrace to the log (for diagnosing a stuck worker). |
| `USR2` | Reopen log files (logrotate) on swarm children. |

The standard deploy dance is **quiet, then stop**: send `TSTP` early in the deploy so
the old worker stops claiming new jobs, then `TERM` once the new release is live. A
`SIGKILL` at any point is safe — reliable fetch keeps in-flight jobs on a per-process
private list in Redis, and they're reclaimed on the next boot.

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
worker: bundle exec wurk -e production
```

Heroku sends `SIGTERM` on dyno cycle, which triggers Wurk's graceful drain — set the
shutdown timeout (`-t`) below Heroku's 30s kill window so jobs finish cleanly.
