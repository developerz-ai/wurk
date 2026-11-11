# Starting the Wurk process

How to boot a Wurk worker — inside Rails (where it usually starts itself) and
standalone, with no Rails engine at all.

> Production init systems (systemd, capistrano, Heroku) and the full signal
> table live in [`docs/deployment.md`](deployment.md). This doc is about getting
> a worker running.

---

## Inside Rails: it auto-starts

In a Rails app you usually start **nothing**. The mountable engine's railtie
boots the swarm as the last step of app initialization, after your own
`after_initialize` hooks, so a normal `rails server` (or a
worker dyno that just boots the app) already has workers forking and fetching.

Set `WURK_DISABLED=1` on any process that should *not* fork workers — typically
your web process if you'd rather run the workers in their own unit:

```bash
WURK_DISABLED=1 bundle exec rails server   # web only, no workers
```

The auto-fork is also skipped automatically in the Rails console and the Rails
test environment, so those never spawn a swarm.

If you'd rather run the worker as its own process even under Rails, disable the
auto-fork as above and use one of the standalone runners below pointed at your
app directory.

### Under a preforking web server (Puma cluster, Unicorn, Passenger)

Auto-fork is only safe from a process that **won't fork itself.** A clustered
Puma, Unicorn, or Passenger already forks its own web workers. Forking the swarm
from one of them is unsafe two ways:

- **No app preloading** — every web worker re-runs the railtie hook and forks
  its own full swarm, multiplying your worker count by the web concurrency.
- **With app preloading** — the swarm boots in the server master, and its
  supervisor thread ends up tangled with the server's own fork and signal
  handling.

So Wurk **refuses** to fork there and logs an actionable notice instead:

```text
wurk: preforking web server detected (Puma cluster / Unicorn / Passenger).
Refusing to fork the worker swarm from a process that forks its own workers.
...
```

Pick one:

- **Run the swarm as its own process — recommended.** `bundle exec wurkswarm`
  (or `wurk`) on its own dyno/unit, the standard production topology. Set
  `WURK_DISABLED=1` on the web process to silence the notice.
- **Run workers inside the web process — threads only, no fork.** Opt into
  embedded mode (the same model as Sidekiq embedded — worker threads share the
  web process, no swarm):

  ```ruby
  # config/application.rb
  config.wurk.embed_in_web = true
  ```

  Set this in `config/application.rb`, **not** an initializer — server mode is
  decided before `config/initializers/*` load, so a later flag would arrive too
  late and your `Sidekiq.configure_server` blocks would be skipped.

Single-mode Puma (`workers 0`, the `rails server` default) is threaded, not
preforking, so auto-fork stays on there — nothing to change for local dev.

Detection is best-effort: a cluster it misses falls back to the normal fork path,
and an over-eager match is always escapable via `embed_in_web`, `WURK_DISABLED=1`,
or simply running `wurkswarm` separately.

---

## The two runners

| Binary | What it does | Sidekiq equivalent |
|---|---|---|
| `bundle exec wurk` | One process, a thread pool | `sidekiq` |
| `bundle exec wurkswarm` | Forks N worker children from one preloaded parent — fork-based real parallelism | `sidekiqswarm` |

`sidekiqswarm` ships as an alias for `wurkswarm`, so an existing Enterprise
invocation drops in unchanged. There is **no `sidekiq` binary** — point any
`bundle exec sidekiq` command at `wurk`.

```bash
bundle exec wurk        -e production            # single process
bundle exec wurkswarm   -e production            # forked swarm (real parallelism)
```

`wurkswarm` is the only way to get fork-based parallelism **without** Rails —
the auto-boot path is Rails-only.

### Common flags

Identical to Sidekiq:

| Flag | Meaning |
|---|---|
| `-c INT` | Processor threads (concurrency). Defaults to `RAILS_MAX_THREADS`, else `5`. |
| `-q queue[,weight]` | Queue to process, optionally weighted. Repeatable. Defaults to `default`. |
| `-r PATH` | App to load — a Rails app **directory**, or a single `.rb` file (see below). |
| `-t NUM` | Shutdown timeout in seconds (default 25). |
| `-e ENV` | Application environment. |
| `-g TAG` | Process tag shown in the procline / dashboard. |
| `-C PATH` | Path to a YAML config file. |
| `-v` | Verbose logging. |

With no `-C`, Wurk auto-discovers `config/wurk.yml`, then `config/sidekiq.yml`
(`.erb` variants too), relative to the required path.

### Pointed at a Rails app (`-r .`)

Both runners fully boot your app via `config/environment.rb`, but neither
*starts* the engine: no engine initializers, no dashboard routes, no assets,
nothing serving HTTP. A worker host stays lean.

That's about the engine's Rails lifecycle, not the constant. `Wurk::Engine`
resolves on demand, so an app whose `config/routes.rb` does
`mount Wurk::Engine => "/wurk"` boots cleanly under `wurk` and `wurkswarm`
exactly as it does under `rails server`. (Through 1.3.0 it did not — the worker
died on boot with `uninitialized constant Wurk::Engine` while the web process was
fine. Fixed in 1.3.1; no `require "wurk/rails"` in routes.rb needed.)

---

## Running without Rails

Wurk's standalone runners pull in no Rails code of their own, so they work in any
Ruby app — a Sinatra service, a plain Rack app, a CLI daemon, whatever. You point
`-r` at a single Ruby file that loads your code and defines your jobs.

**1. A boot file that requires your app and defines jobs:**

```ruby
# app.rb
require "wurk"

Wurk.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end

require_relative "lib/my_app"   # your own code / job classes

class EmailJob
  include Sidekiq::Worker       # or `include Wurk::Job` — same thing
  def perform(user_id)
    MyApp.deliver_welcome(user_id)
  end
end
```

**2. Start a worker against it:**

```bash
bundle exec wurk      -r ./app.rb -q default -c 5      # single process
bundle exec wurkswarm -r ./app.rb -q default           # forked swarm
```

When `-r` is a **file**, Wurk just `require`s it. When `-r` is a **directory**
it's treated as a Rails app root and `config/environment.rb` is loaded instead —
that's the only Rails-aware branch, and it's the host app's call, not the gem's.

**3. Enqueue from anywhere** (web process, console, cron) — just load `wurk`,
point it at the same Redis, and call the job:

```ruby
require "wurk"
Wurk.configure_client { |c| c.redis = { url: ENV.fetch("REDIS_URL") } }

EmailJob.perform_async(42)        # or EmailJob.perform_in(5.minutes, 42)
```

### Config file instead of flags

Anything you can pass as a flag can live in a YAML file (handy for the swarm's
queue/concurrency topology). Per-environment overlays work like Sidekiq's:

```yaml
# config/wurk.yml
:concurrency: 10
:queues:
  - critical            # plain list = strict priority (first wins)
  - default

:production:
  :concurrency: 25
```

For weighted fetch, give every queue a weight (Sidekiq's nested-array form). Mixing
weighted and unweighted entries puts the unweighted ones at weight 0, so weight them
all:

```yaml
:queues:
  - [critical, 2]
  - [default, 1]
```

```bash
bundle exec wurk -C config/wurk.yml -e production
```

ERB is evaluated, so `<%= ENV["..."] %>` works inside the file.

---

## Boot messages

A process that runs jobs says what it is in one INFO line, and every boot path
checks a few things that otherwise surface only under load. `bundle exec wurk
boot-check -r .` runs the same boot and the same checks, then exits without
forking or fetching, so a CI step sees them first. It boots as `wurkswarm` by
default; `--runner wurk` boots the single-process path instead, for an app that
deploys `wurk`.

What boot-check runs, and what it does not:

- The app's initializers and `configure_server` blocks run: their load errors
  are what it is for.
- No lifecycle event fires (`:startup` included), no periodic loop is
  registered, nothing is forked and nothing is fetched.
- Without `--redis`, every Redis pool Wurk builds refuses to open a connection,
  so boot code that writes Redis (a dev-only `flushdb`, a seed) fails the check,
  naming its file and line, instead of reaching a server. With `--redis` those
  pools send reads only (the allowlist `wurk preflight` uses), and the check also
  reports the server version, eviction policy and live peers. A client the app
  opens itself (`Redis.new`, `Rails.cache`) is not Wurk's and is not covered.
  Redis work that belongs to a running worker goes in `config.on(:startup)`.

`wurk preflight --app` boots the app behind the same read-only guard.

| Message | Level | Cause | Fix |
|---|---|---|---|
| `wurk: <role>; N processes × M threads (redis pool P, fetch F); AR pool A` | INFO | Logged once at boot by the process that runs or forks job threads (`wurk`, the `wurkswarm` parent, the swarm or embedded workers in a Rails server). `AR pool` appears only with Active Record configured | Nothing to fix; check the sizes are the ones you meant |
| `wurk: client only (<reason>); this process enqueues and runs no jobs` | DEBUG | The Rails integration skipped worker boot: `WURK_DISABLED=1`, a build or rake task, the Rails console, the test environment, or not a web server | `WURK_EMBED=1` runs jobs in a process that is not a web server |
| ``These jobs set `unique_for:` or `unique_until:` but unique jobs are not enabled…`` | WARN | `Sidekiq::Enterprise.unique!` was never called, so those options do nothing | Call `Sidekiq::Enterprise.unique!` once in an initializer ([unique jobs](unique-jobs.md)) |
| ``These jobs set `lock:` but sidekiq-unique-jobs is not loaded…`` | WARN | `lock:` is sidekiq-unique-jobs' option and nothing reads it without the gem | Keep the gem through the shim, or move the jobs to `unique_for:` |
| `The bundle holds the real sidekiq <version> gem…` | ERROR | A gem that depends on `sidekiq` pulled the real gem in beside Wurk, so `Sidekiq::*` is part theirs, part Wurk's. Logged as Wurk loads, in every process | Replace it with the shim line the message prints (pinned to your Wurk version). `WURK_STRICT=1` turns the message into a raise that refuses to boot |
| `The Active Record pool holds A connections but this process runs up to M job threads…` | WARN | `pool:` in `config/database.yml` is below the job threads one process runs; jobs that use the database wait, then raise `ActiveRecord::ConnectionTimeoutError` | Set `pool:` to at least M, plus the web server's threads when jobs run in the web process. Worker processes also log an ERROR (`ActiveRecord connection pool size … is smaller than…`) for the same condition |
| `the Redis pool for capsule <name> holds S connections, fewer than its concurrency of C…` | refuses to start | `config.redis = { size: S }` is below a capsule's concurrency (`wurk`, `wurkswarm`, `wurk boot-check`) | Raise `size:` to at least C, or drop `size:` and Wurk sizes the pool itself (concurrency + 5, at least 10) |
| `Wurk swarm size: N children (<source>)` | INFO | How many children a swarm without a declared topology runs, and where the number came from (`WURK_COUNT`, `SIDEKIQ_COUNT`, or the CPU count) | Set `WURK_COUNT` if it is not the number you meant |
| `wurk boot-check: <file>:<line> opened a Redis connection while the app booted…` / `…sent <COMMAND> while the app booted…` | fails the check | Boot code touched Redis under `wurk boot-check` (or wrote it under `--redis`, or under `wurk preflight --app`) | Move the Redis work into `config.on(:startup)`; pass `--redis` if the boot only needs to read |
| `This is a server process, so its configure_client blocks were skipped, and no configure_server block ran…` | WARN | The app configures Wurk only in `configure_client`, so the workers got none of it (Redis settings, middleware, handlers). A client block skipped next to a server block is the normal Sidekiq shape and logs only at DEBUG | Repeat the settings in a `configure_server` block, or set them outside both |
| `config.topology is set, but wurk runs a single process and ignores it…` | WARN | A topology only shapes what `wurkswarm` forks; `wurk` and a worker embedded in the web server run the capsules' threads in one process | Run `wurkswarm`, or set queues and concurrency on the capsules |
| `Rails enqueues to <queue> (<what>), which neither this process nor any live one listens to…` | WARN | ActiveJob runs on Wurk, and a queue Rails sends its own jobs to (mail delivery, Active Storage, Action Mailbox) is in no process's queue list, so those jobs wait forever. Checked when Redis is read: `wurk`, `wurkswarm`, `wurk boot-check --redis` | Add the queue to a worker. A leader also warns, once a queue has held jobs unconsumed for five minutes |
| `Redis pool <name> uses the hiredis driver under a fiber scheduler…` | WARN | `driver: :hiredis` in a process with a fiber scheduler (Falcon, Async): hiredis waits in C, so one slow reply stalls every fiber on the thread | Use `driver: :ruby` in that process's `config.redis` |

The `lock:` and `unique_for:` checks see only job classes loaded by then: under
lazy loading, a class first touched later is not listed.

A `read_timeout` below the fetch's block window is fine: the reliable fetcher's
`BLMOVE` is a blocking call, and redis-client waits for the window plus
`read_timeout`. Wurk's default is 2.5s. Set Redis options before anything uses
Redis, though: a pool built before `config.redis=` keeps the settings it was built
with (a WARN says so), and only a swarm child rebuilds its pools.

---

## Stopping it

Send `TERM` (or `INT`) for a graceful drain — fetching stops, in-flight jobs
finish up to the shutdown timeout (`-t`, default 25s), then the process exits. A
`SIGKILL` is always safe: reliable fetch keeps in-flight jobs on a per-process
private list in Redis and reclaims them on the next boot. The full signal table
(quiet, rolling restart, thread dump, log reopen) is in
[`docs/deployment.md`](deployment.md#signals).
