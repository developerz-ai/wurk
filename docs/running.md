# Starting the Wurk process

How to boot a Wurk worker — inside Rails (where it usually starts itself) and
standalone, with no Rails engine at all.

> Production init systems (systemd, capistrano, Heroku) and the full signal
> table live in [`docs/deployment.md`](deployment.md). This doc is about getting
> a worker running.

---

## Inside Rails: it auto-starts

In a Rails app you usually start **nothing**. The mountable engine's railtie
boots the swarm during `after_initialize`, so a normal `rails server` (or a
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

```
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

---

## Running without Rails

Wurk's standalone runners never load the engine, so they work in any Ruby app —
a Sinatra service, a plain Rack app, a CLI daemon, whatever. You point `-r` at a
single Ruby file that loads your code and defines your jobs.

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

## Stopping it

Send `TERM` (or `INT`) for a graceful drain — fetching stops, in-flight jobs
finish up to the shutdown timeout (`-t`, default 25s), then the process exits. A
`SIGKILL` is always safe: reliable fetch keeps in-flight jobs on a per-process
private list in Redis and reclaims them on the next boot. The full signal table
(quiet, rolling restart, thread dump, log reopen) is in
[`docs/deployment.md`](deployment.md#signals).
