# Configuration reference

Every knob Wurk reads, where it comes from, and what it defaults to. The
authoritative source for each row is `lib/wurk/configuration.rb`,
`lib/wurk/capsule.rb`, `lib/wurk/cli.rb`, `lib/wurk/redis_pool.rb`, and
`lib/wurk/logger.rb`.

Configuration arrives from four places:

| # | Source | Applies to | Where |
|---|--------|-----------|-------|
| 1 | Ruby (`Wurk.configure_server` / `configure_client`) | every runner | `config/initializers/wurk.rb` |
| 2 | CLI flags | `wurk`, `wurkswarm` only | command line |
| 3 | YAML config file | `wurk`, `wurkswarm` only | `config/wurk.yml`, `config/sidekiq.yml` |
| 4 | Environment variables | every runner | process env |
| 5 | `Configuration::DEFAULTS` | fallback | `lib/wurk/configuration.rb` |

`Sidekiq.configure_server`, `Sidekiq.configure_client`, `Sidekiq.configure_embed`
and `Sidekiq::Config` are aliases for the Wurk equivalents, so an existing
Sidekiq initializer works unchanged.

> **The Rails engine never reads CLI flags or YAML.** When the railtie auto-boots
> the swarm inside a Rails host, options 2 and 3 don't exist — configure in Ruby
> and env. The YAML file and flags belong to the standalone `wurk` / `wurkswarm`
> binaries.

---

## Precedence

For the standalone runners, `Wurk::CLI#parse` builds options in this order
(`setup_options`):

1. Parse CLI flags into `opts`.
2. Resolve the environment: `-e` → `APP_ENV` → `RAILS_ENV` → `RACK_ENV` →
   `"development"`.
3. Locate the YAML file (`-C`, else auto-discovery).
4. `parse_config(file).merge(opts)` — **CLI flags win over YAML**. Inside the
   YAML, the per-environment section is merged over the top-level keys, so
   **environment overlay wins over top-level**.
5. `queues` defaults to `["default"]`; `concurrency` falls back to
   `RAILS_MAX_THREADS` **only if neither CLI nor YAML set it**.
6. Merge the result into the `Wurk::Configuration`.

Then `Wurk::CLI#run` boots your application — which is when
`config/initializers/wurk.rb` runs. So:

```
Ruby (configure_server)  >  CLI flags  >  YAML env overlay  >  YAML top-level
                         >  RAILS_MAX_THREADS (concurrency only)  >  DEFAULTS
```

**Ruby wins because it runs last.** `config.concurrency = 10` in an initializer
overrides `wurk -c 4`. This matches Sidekiq. If you want the flag to win, read
the env/flag yourself in the initializer, or don't set the value in Ruby.

Env vars that have no Ruby/CLI/YAML equivalent (`WURK_COUNT`, `WURK_DISABLED`,
`WURK_PRELOAD*`, `WURK_LEADER`) are read directly at the point of use and are
not part of this chain. Two env vars *are* overridable from Ruby, and there the
explicit Ruby value wins: `SIDEKIQ_MAXMEM_MB`/`WURK_MAXMEM_MB` (beaten by
`config.memory_limit_mb =`) and `WURK_WEB_READ_ONLY` (beaten by a later
`config.web.read_only =`).

---

## `configure_server` / `configure_client`

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.redis       = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
  config.concurrency = 10
  config.queues      = %w[critical default low]
  config[:timeout]   = 25
end

Wurk.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
```

The Sidekiq alias forms are identical in behavior:

```ruby
Sidekiq.configure_server { |config| config.concurrency = 10 }
Sidekiq.configure_client { |config| config.redis = { url: ENV["REDIS_URL"] } }
```

- The block yields the **same** `Wurk::Configuration` singleton
  (`Wurk.configuration`) in both cases.
- `configure_server` runs its block only when `config[:server] == true`;
  `configure_client` only when it is not.
- Server mode is entered **before** initializers load — by the
  `wurk.server_mode` railtie initializer in a Rails host, and by
  `Wurk.enter_server_mode` in `Wurk::CLI#run` / `#run_swarm` before the app is
  required. A Rails process that will not run workers (see `WURK_DISABLED`,
  Rails console, test env, a refused preforking boot) is *not* a server, so its
  `configure_server` blocks are skipped and `configure_client` blocks run.
- Both are safe to call multiple times; blocks accumulate side effects on the
  one config object.

Embedded mode (threads in your own process, no fork):

```ruby
instance = Wurk.configure_embed do |config|
  config.queues = %w[default]
end
instance.run     # then #quiet / #stop
```

`configure_embed` forces `config.concurrency = 2` before yielding — the GIL
makes more threads counterproductive inside a host process that has its own
pool — and raises `FrozenError` if the configuration has already been frozen by
a running launcher.

---

## Config options

`Wurk::Configuration` is hash-like: `config[:key]`, `config[:key] = v`,
`fetch`, `key?`/`has_key?`, `merge!`, `dig`. Third-party gems rely on this, so
every option below is readable that way even when a named accessor also exists.

### `DEFAULTS`

Verbatim from `Wurk::Configuration::DEFAULTS`.

| Option | Type | Default | Meaning |
|---|---|---|---|
| `:labels` | `Set` | `Set.new` | Free-form labels published in the heartbeat and shown in the dashboard |
| `:require` | String | `"."` | Rails app dir or `.rb` file the standalone CLI loads (`-r`) |
| `:environment` | String / nil | `nil` | App environment; set by `-e` / `APP_ENV` / `RAILS_ENV` / `RACK_ENV` |
| `:concurrency` | Integer | `5` | Threads per worker process (seeds the default capsule) |
| `:timeout` | Integer | `25` | Seconds in-flight jobs get to finish on shutdown |
| `:poll_interval_average` | Float / nil | `nil` | Scheduler poll interval; `nil` → `process_count × average_scheduled_poll_interval` |
| `:average_scheduled_poll_interval` | Integer | `5` | Per-process factor for the scaled scheduler interval |
| `:on_complex_arguments` | `:raise`/`:warn`/`false` | `:raise` | What `verify_json` does with non-JSON-native job arguments |
| `:max_iteration_runtime` | Integer / nil | `nil` | Accepted for drop-in compatibility; **not consumed by Wurk** |
| `:error_handlers` | Array | `[]` → seeded with `ERROR_HANDLER` | `(ex, ctx, cfg)` callables |
| `:death_handlers` | Array | `[]` | `(job, ex)` callables run when a job exhausts retries |
| `:lifecycle_events` | Hash | `{startup: [], fork: [], quiet: [], shutdown: [], exit: [], heartbeat: [], beat: [], leader: []}` | Registered via `config.on(...)` |
| `:dead_max_jobs` | Integer | `10_000` | Dead set is trimmed to this many entries on every kill |
| `:dead_timeout_in_seconds` | Integer | `15_552_000` (180 days) | Dead entries older than this are trimmed |
| `:reloader` | callable | `proc { |&b| b.call }` | Wraps each job execution (Rails sets the code reloader) |
| `:backtrace_cleaner` | callable | `->(bt) { bt }` | Filters backtraces stored on the retry/dead payload |
| `:logged_job_attributes` | Array\<String\> | `["bid", "tags"]` | Job hash keys copied into the log context |
| `:redis_idle_timeout` | Integer / nil | `nil` | Accepted for drop-in compatibility; **not consumed by Wurk** |
| `:redis_error_handlers` | Array | `[]` | Registered via `config.on_redis_error`; receives one Hash |

### Additional keys read at runtime

Not in `DEFAULTS` — unset unless you assign them.

| Option | Type | Default when unset | Meaning |
|---|---|---|---|
| `:tag` | String | basename of the app dir | Process tag shown in the dashboard / procline (`-g`) |
| `:identity` | String | `<hostname>:<pid>:<nonce>` | Set by the CLI before boot; the heartbeat key |
| `:verbose` | Boolean | `false` | `-v`; raises the logger to `DEBUG` |
| `:server` | Boolean | `false` | Set by `Wurk.enter_server_mode`; gates `configure_server` |
| `:max_retries` | Integer | `25` | Default retry attempts (`JobRetry::DEFAULT_MAX_RETRY_ATTEMPTS`) |
| `:fetch_class` | Class | `Wurk::Fetcher::Reliable` | Custom fetcher class, instantiated per capsule |
| `:fetch_setup` | callable | — | Called with the freshly built fetcher |
| `:fetch_poll_interval` | Numeric | `2` (`Fetcher::Reliable::TIMEOUT`) | BLMOVE block seconds when every served queue is empty |
| `:scheduled_enq` | Class | poller default | Set to `Wurk::Scheduled::ReliableEnq` by `config.reliable_scheduler!` |
| `:job_logger` | Class | `Wurk::JobLogger` | Per-job start/done logger |
| `:skip_default_job_logging` | Boolean | `false` | Silences the per-job start/done lines |
| `:scheduler_initial_wait` | Numeric | `10` | Seconds before the scheduler's first sweep |
| `:cron_tick_interval` | Numeric | `60` | Periodic (cron) tick cadence |
| `:metrics_rollup_interval` | Numeric | `60` | Leader-only metrics + per-queue gauge rollup cadence |
| `:super_fetch_reaper_interval` | Numeric | `60` | Orphan-reclamation sweep cadence |
| `:leader_ttl` | Integer | `30` | Cluster leader lock TTL |
| `:leader_renew_interval` | Integer | `15` | Leader renew cadence |
| `:leader_follower_interval` | Integer | `60` | Follower re-campaign cadence |
| `:history_stream_cap` | Integer | `10_000` | Cap on the historical-metrics stream |
| `:health_check_options` | Hash | — | Set by `config.health_check(port:)` |
| `:web_pool_size` | Integer | `5` | Connections in the dedicated dashboard Redis pool |

### Named accessors and methods

| Call | Notes |
|---|---|
| `config.concurrency` / `= n` | Threads per process; reads/writes the **default capsule** |
| `config.queues` / `= [...]` | Ordered/weighted queue list on the default capsule |
| `config.total_concurrency` | Sum of `concurrency` across all capsules |
| `config.capsule(name) { |cap| … }` | Create/lookup a capsule |
| `config.default_capsule { |cap| … }` | The `"default"` capsule |
| `config.client_middleware { |chain| … }` | Client chain |
| `config.server_middleware { |chain| … }` | Server chain |
| `config.redis = { … }` | Merges into the Redis connection hash |
| `config.redis { |conn| … }` | Checkout from the default capsule's main pool |
| `config.redis_pool` | Default capsule's main pool |
| `config.new_redis_pool(size, name = "custom")` | Build an extra pool |
| `config.web_pool_size` / `= n` | Dashboard pool size (default `5`) |
| `config.web_redis_pool` | Lazily built dashboard pool |
| `config.reset_redis_pools!` | Disconnect + drop every cached pool (used around fork) |
| `config.on_redis_error { |info| … }` | Telemetry on pool retries/give-ups |
| `config.error_handlers` / `config.death_handlers` | Arrays of callables |
| `config.handle_exception(ex, ctx = {})` | Dispatch to the error handlers |
| `config.on(event) { … }` | Lifecycle hook |
| `config.logger` / `= logger` | Process logger |
| `config.thread_priority` / `= n` | Default `-1`; stored, **not applied** by Wurk |
| `config.register(name, obj)` / `config.lookup(name, default_class = nil)` | Extension service locator |
| `config.topology` / `= Wurk::Topology…` | Swarm layout |
| `config.memory_limit_mb` / `= n` | RSS recycle threshold; `nil`/`0` disables |
| `config.periodic { |mgr| … }` | Cron registration (`mgr.register(cron, JobClass, **opts)`) |
| `config.retain_history(seconds = 30) { |s| … }` | Ent historical-metrics snapshotter |
| `config.dogstatsd = -> { … }` | Statsd/Dogstatsd client factory, invoked once per process after fork |
| `config.health_check(port:, bind: "0.0.0.0", ready_window: 30)` | Opt-in `/live` + `/ready` listener |
| `config.web` | The `Wurk::Web.config` singleton (see [authentication.md](authentication.md)) |
| `config.super_fetch!` | Sidekiq Pro toggle; reliable fetch is already the default, so this is a no-op apart from capturing its optional recovery block |
| `config.reliable_scheduler!` | **Not a no-op.** Swaps `:scheduled_enq` to the atomic promoter. The default poller pops then pushes and has a job-loss window — see [Reliability](reliability.md) |
| `config.fetch_poll_interval` / `= seconds` | Empty-poll BLMOVE backoff |
| `config.freeze!` / `config.frozen?` | The launcher freezes options + capsules at boot |

`config.freeze!` runs in `Launcher#run`, so every mutation must happen before
workers start. Post-freeze writes raise `FrozenError`.

---

## Environment variables

Every `ENV` read in `lib/`. `WURK_*` is the native name; the `SIDEKIQ_*` form
is the drop-in alias and is checked second (native wins).

| Variable | Read by | Effect |
|---|---|---|
| `REDIS_URL` | `Configuration#initialize`, `RedisPool::DEFAULT_URL` | Redis URL. Default `redis://localhost:6379/0` |
| `WURK_COUNT` / `SIDEKIQ_COUNT` | `Configuration#default_child_count` | Swarm child processes. Whole number = absolute count; fractional = CPU multiplier (`0.5` → half the cores, rounded). Floored at 1. Unparseable → CPU count. Default `Etc.nprocessors` |
| `WURK_MAXMEM_MB` / `SIDEKIQ_MAXMEM_MB` | `Configuration#memory_limit_mb` | Parent TERMs + respawns any child whose RSS exceeds this. Unset/unparseable → recycling off |
| `WURK_DISABLED` | `RailsBoot.skip_boot?` | `=1` skips both server mode and the swarm boot in a Rails host |
| `WURK_LEADER` / `SIDEKIQ_LEADER` | `Leader.opted_out?` | `=false` (case-insensitive) makes this process never campaign for leadership |
| `WURK_PRELOAD` / `SIDEKIQ_PRELOAD` | `CLI#preload_groups` | Comma-separated Bundler groups `Bundler.require`d in the swarm parent before fork. Default `default`; an explicit empty value disables the preload |
| `WURK_PRELOAD_APP` / `SIDEKIQ_PRELOAD_APP` | `CLI#preload_app?` | `=1` eager-loads the whole Rails app in the swarm parent before forking (more copy-on-write sharing, slower parent boot) |
| `WURK_WEB_READ_ONLY` | `Web::Config#env_read_only?` | `=1` boots the dashboard in read-only mode |
| `WURK_DEBUG` | `Configuration::ERROR_HANDLER` | Any value makes the default error handler log `full_message` (with backtrace) instead of `detailed_message` |
| `WURK_VITE_DEV` | `Engine`, `DashboardController` | `=1` serves the SPA from the Vite dev server instead of the precompiled bundle |
| `RAILS_MAX_THREADS` | `CLI#apply_defaults!` | Fallback `concurrency` when neither CLI nor YAML set it |
| `APP_ENV`, `RAILS_ENV`, `RACK_ENV` | `CLI#set_environment` | Environment, in that order, after `-e`. Default `development`. The CLI then writes `RACK_ENV`/`RAILS_ENV` back before booting the app |
| `DEBUG_INVOCATION` | `CLI#initialize_logger` | `=1` sets the logger to `DEBUG` (same as `-v`) |
| `RUBY_DISABLE_WARMUP` | `CLI#run`, `#run_swarm` | `=1` skips `Process.warmup` |
| `DYNO` | `Component#hostname`, `Logger`, `Fetcher::Reliable`, `Leader` | Heroku: used as the hostname in the process identity and switches the log formatter to the timestamp-less variant |
| `WEB_CONCURRENCY` | `RailsBoot#puma_worker_count` | Read only to detect Puma cluster mode when Puma's parsed config is unavailable |
| `SECRET_KEY_BASE_DUMMY` | `RailsBoot#building?` | Presence marks a build/precompile step; the swarm never forks there |

There is **no `WURK_CONCURRENCY`**. Threads per process are
`config.concurrency` / `-c` / `RAILS_MAX_THREADS`.

---

## YAML config file

Read only by `wurk` and `wurkswarm`. Pass `-C path`, or let the CLI
auto-discover, in `<require-dir>/config/`, the first of:

```
wurk.yml   wurk.yml.erb   sidekiq.yml   sidekiq.yml.erb
```

Files are run through ERB (`trim_mode: "-"`) then `YAML.safe_load` with
`permitted_classes: [Symbol], aliases: true`. Keys are symbolized recursively,
so `concurrency:` and `:concurrency:` are equivalent.

```yaml
# config/wurk.yml
:concurrency: 5
:timeout: 25
:queues:
  - default
  - [critical, 2]        # weighted; "critical,2" also works
:capsules:
  high_priority:
    :concurrency: 3
    :queues:
      - critical

production:
  :concurrency: 10
  :queues:
    - critical
    - default
```

- A top-level key matching the resolved environment (`production:`, `staging:`,
  …) is an **overlay**: it is deleted from the hash and merged over the
  top-level keys.
- `:strict` is dropped — Sidekiq removed strict fetch in 8.x.
- `:capsules` is the only nested section with special handling; per capsule only
  `:queues` and `:concurrency` are honored.
- Every other key is merged into the config's option hash verbatim, so any
  option from the tables above (`:tag`, `:max_retries`, `:dead_max_jobs`,
  `:fetch_poll_interval`, …) can be set from YAML.
- Queue entries accept `name`, `"name,weight"`, `[name]`, and `[name, weight]`.
  Weight `0` is not allowed; a weight must be `> 0`.

---

## CLI flags

`wurk` (single process, one thread pool) and `wurkswarm` (parent forks
`WURK_COUNT` children and supervises them) share one option parser.
`sidekiqswarm` is shipped as an alias for `wurkswarm`. There is no `sidekiq`
binary.

| Flag | Option | Notes |
|---|---|---|
| `-c`, `--concurrency INT` | `:concurrency` | Processor threads per process |
| `-e`, `--environment ENV` | `:environment` | App environment |
| `-g`, `--tag TAG` | `:tag` | Process tag for the procline / dashboard |
| `-q`, `--queue QUEUE[,WEIGHT]` | `:queues` | Repeatable; appends |
| `-r`, `--require [PATH\|DIR]` | `:require` | Rails app dir or a single `.rb` file |
| `-t`, `--timeout NUM` | `:timeout` | Shutdown grace seconds |
| `-v`, `--verbose` | `:verbose` | `DEBUG` logging |
| `-C`, `--config PATH` | `:config_file` | YAML config path |
| `-V`, `--version` | — | Print version and exit |
| `-h`, `--help` | — | Print help and exit |

```bash
bundle exec wurkswarm -C config/wurk.yml -e production   # forked swarm
bundle exec wurk      -r ./app.rb -q critical,2 -q default -c 10
```

Boot validation, in order: the `-r` path must exist (and, for a directory,
contain `config/application.rb`); `concurrency` and `timeout` must both be
`> 0`; Redis must report `>= 7.0.0`; a non-`noeviction` `maxmemory-policy`
logs a warning; and every capsule's pool size must be `>= its concurrency`
(`Pool size too small for <capsule>` otherwise).

Neither runner *starts* the Rails engine — no engine initializers, no dashboard
routes, no assets, so a worker host stays lean and serves no dashboard — but both
fully boot your app. The `Wurk::Engine` constant itself still resolves on demand,
so an app whose `config/routes.rb` mounts the dashboard boots cleanly under
`wurk` / `wurkswarm` too (before 1.3.1 it died there with `uninitialized constant
Wurk::Engine`).

---

## Redis connection and pool sizing

```ruby
Wurk.configure_server do |config|
  config.redis = {
    url:                ENV.fetch("REDIS_URL"),
    size:               15,      # pins the capsule's main pool
    pool_timeout:       1.0,     # checkout wait
    connect_timeout:    1.0,
    read_timeout:       2.5,
    write_timeout:      2.5,
    reconnect_attempts: 1
  }
end
```

`config.redis =` **merges** into the existing hash. `:size`, `:name`,
`:pool_timeout` and `:pool_name` are pool-structural and consumed by Wurk;
everything else forwards to redis-client (so `driver:`, `ssl_params:`,
`username:`, `password:`, `sentinels:`, … pass through).

> **`REDIS_URL` / `password:` are secret** when they embed credentials, and
> `REDIS_URL` is the only secret-bearing value Wurk reads from the environment
> itself. For where it (and the encryption key, dashboard credentials, and
> Sentry DSN) should live and what must never be committed, see
> [secrets.md](secrets.md).

Sidekiq-era spellings are translated rather than forwarded, so an existing
initializer needs no edit:

| You wrote | Wurk does |
|---|---|
| `network_timeout: 5` / `timeout: 5` | fans out to `connect_timeout` / `read_timeout` / `write_timeout` (an explicit one of those wins) |
| `master_name: "mymaster"` | → `name:`, and `sentinels:` routes the pool through `RedisClient.sentinel` |
| `driver: "hiredis"`, `role: "master"` | symbolized |
| `logger:`, `cluster_safe:`, `pool_name:` | accepted and dropped, as Sidekiq does |
| `namespace:` | raises — Wurk has no namespacing; give it its own Redis db or instance |
| `nodes:` | raises — Redis Cluster is unsupported |

Anything redis-client would reject raises on assignment, naming the key and
listing the supported set, so a typo fails in the process running your
initializer instead of inside a forked worker child.

| Key | Default | Source |
|---|---|---|
| `url` | `ENV["REDIS_URL"]` or `redis://localhost:6379/0` | `RedisPool::DEFAULT_URL` |
| `pool_timeout` | `1.0` | `RedisPool::DEFAULT_POOL_TIMEOUT` |
| `connect_timeout` | `1.0` | `RedisPool::DEFAULT_CONNECT_TIMEOUT` |
| `read_timeout` | `2.5` | `RedisPool::DEFAULT_READ_TIMEOUT` |
| `write_timeout` | `2.5` | `RedisPool::DEFAULT_WRITE_TIMEOUT` |
| `reconnect_attempts` | `1` | `RedisPool::DEFAULT_RECONNECT_ATTEMPTS` |

### Three disjoint pools

Each worker process opens more than one pool, deliberately — a dashboard burst
must not starve fetch or heartbeat.

| Pool | Size | Used by |
|---|---|---|
| `<capsule>-main` | `config.redis[:size]`, else `max(concurrency + 5, 10)` | Heartbeat, scheduler, leader election, cron, metrics rollups, reaper, history, health probe, and your job code |
| `<capsule>-fetch` | `concurrency` | Only the reliable fetcher's blocking `BLMOVE` |
| `web` | `config.web_pool_size` (default `5`), checkout timeout pinned to `1.0` | Dashboard, JSON API, SSE |

Setting `config.redis[:size]` pins **the main pool only**; the fetch pool
always tracks `concurrency` and the web pool always tracks `web_pool_size`.

Redis connections are **never shared across forks**: the swarm parent calls
`reset_redis_pools!` before forking and each child rebuilds lazily.

### Transient-failure handling

`RedisPool#with` absorbs blips before raising:

- `READONLY` / `NOREPLICAS` / `UNBLOCKED` — a failover; close and retry once
  immediately.
- `RedisClient::ConnectionError` — close, sleep `(0.5 × 2ⁿ) + rand×0.25`, retry
  up to 3 attempts total, then raise.
- `ConnectionPool::TimeoutError` — one retry after `0.1–0.3s`, then raise.
  Sustained checkout starvation is a sizing bug; fix the size.

Every retry and final give-up is reported to `config.on_redis_error`:

```ruby
Wurk.configure_server do |config|
  config.on_redis_error do |info|
    # info => { error: <exception>, attempt: 1, retried: true, pool: "default-main" }
    Sentry.capture_message("redis retry", extra: info) unless info[:retried]
  end
end
```

Handlers are opt-in (the array starts empty) and a raising handler is logged and
skipped.

---

## Concurrency vs parallelism

Two independent knobs. Consistent with
[migrate-from-sidekiq.md §2](migrate-from-sidekiq.md#2-concurrency-vs-parallelism-read-this).

| Knob | Controls | Set with | Default |
|---|---|---|---|
| **Parallelism** | Forked worker **processes** | `WURK_COUNT` (alias `SIDEKIQ_COUNT`), or an explicit `config.topology` | CPU core count (`Etc.nprocessors`) |
| **Concurrency** | **Threads per process** | `config.concurrency`, `-c`, YAML `:concurrency`, `RAILS_MAX_THREADS` | `5` |

```text
Total in-flight jobs = WURK_COUNT × concurrency
16-core box, defaults: 16 processes × 5 threads = 80 jobs at once
                                                + 16 separate DB connection pools
```

`WURK_COUNT` only applies to the **forking** runners: the Rails engine's
auto-boot swarm and `wurkswarm`. Plain `wurk` is a single process and ignores
it. A whole number is an absolute count; a fractional value is a CPU multiplier
(`0.5` → half the cores, rounded); the result is floored at 1.

Sizing:

```bash
WURK_COUNT=2 bundle exec wurkswarm   # 2 × 5 = 10 in flight (matches a Sidekiq concurrency:10 box)
WURK_COUNT=4 bundle exec wurkswarm   # 4 × 5 = 20 in flight
bundle exec wurk -c 10               # single process, 10 threads, Sidekiq-shaped
```

Each forked process opens its own DB pool, Redis pools, and memory footprint.
Size `database.yml`'s `pool` for the **per-process** thread count, then check
`WURK_COUNT × pool` against your database's spare connections. Start with
`WURK_COUNT` = cores you want to dedicate to jobs and `concurrency = 5` for
IO-bound work; raise `concurrency` for IO-heavy jobs, `WURK_COUNT` for CPU-heavy
ones.

Memory-based recycling caps the damage:

```ruby
Wurk.configure_server { |config| config.memory_limit_mb = 1024 }
# or: SIDEKIQ_MAXMEM_MB=1024 / WURK_MAXMEM_MB=1024
```

The swarm parent checks child RSS every 10s and TERMs + respawns any child over
the limit. `nil` or `0` disables it (the default).

---

## Capsules

A capsule is one processing unit: a set of threads and queues with its own
fetcher, middleware chains, and Redis pools. The `"default"` capsule is created
implicitly, and `config.concurrency` / `config.queues` read and write it.

```ruby
Wurk.configure_server do |config|
  config.concurrency = 5
  config.queues      = %w[default low]

  config.capsule("critical") do |cap|
    cap.concurrency = 2
    cap.queues      = %w[critical]
  end
end
```

| Capsule member | Notes |
|---|---|
| `cap.name` | String |
| `cap.concurrency` / `= n` | Threads; defaults to `config[:concurrency]` (else `5`) |
| `cap.queues` / `= [...]` | Weight-expanded list; default `["default"]` |
| `cap.queue_specs` | Lossless `"name,weight"` round-trip form |
| `cap.mode` | `:strict` (all weights 0) · `:random` (all weights equal, non-zero) · `:weighted` |
| `cap.weights` | `{queue => weight}` |
| `cap.redis_pool` / `cap.redis { }` | Main pool |
| `cap.fetch_redis_pool` / `cap.fetch_redis { }` | Fetch-only pool |
| `cap.client_middleware` / `cap.server_middleware` | Capsule-bound copies of the global chains |
| `cap.fetcher` / `= obj` | Defaults to `Wurk::Fetcher::Reliable` |

Queue mode is derived, not declared: `%w[high default low]` → `:strict`;
`%w[high,3 default,2 low,1]` → `:weighted`; `%w[a,1 b,1 c,1]` → `:random`.

Each capsule gets its own `Manager` inside every worker process, so a
three-capsule config on a 4-process swarm runs 12 managers.
`config.total_concurrency` sums threads across capsules.

## Topology

Capsules split queues *inside* a process. The topology DSL splits them *across*
forked processes — stronger isolation, since a wedged slot can't starve another
slot's threads.

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.topology = Wurk::Topology.new
    .slot(count: 2, queues: %w[critical],      concurrency: 3)
    .slot(count: 4, queues: %w[default low,2], concurrency: 10)
end
```

| Method | Notes |
|---|---|
| `Topology#slot(count:, queues:, concurrency:)` | Declares one *kind* of fork; returns `self` so calls chain. `count` and `concurrency` must be positive Integers; `queues` must be non-empty |
| `Topology.flat(count:, queues:, concurrency:)` | Convenience: `count` identical forks |
| `#slots` / `#assignments` / `#total_processes` | `assignments` is the flat ordered fork list (a `count: 2` slot yields two entries) |
| `#empty?` | No slots declared |

When you don't assign a topology, `config.topology` builds
`Topology.flat(count: <WURK_COUNT or Etc.nprocessors>, queues: <default capsule queue_specs>, concurrency: <default capsule concurrency>)`.
An explicit topology therefore **supersedes `WURK_COUNT`** — the process count
comes from the slots.

Each child applies its slot's queues and concurrency to the default capsule
after fork, before its launcher starts.

---

## Error handlers and death handlers

### `config.error_handlers`

Called for every exception Wurk catches — job failures, heartbeat errors,
scheduler errors. **Signature: `(exception, context_hash, config)`.** The third
argument has a default in the shipped handler, but always accept three.

```ruby
Wurk.configure_server do |config|
  config.error_handlers << ->(ex, ctx, cfg) do
    Sentry.capture_exception(ex, extra: ctx)
  end
end
```

- The array is seeded with `Wurk::Configuration::ERROR_HANDLER` when it is empty
  at construction time. Appending keeps the default logging; assigning a fresh
  array replaces it.
- `ctx` typically carries `:context` plus `:job` / `:jid` where available.
- `config.handle_exception(ex, ctx)` runs the chain; a handler that raises is
  logged (`error_handler raised: …`) and the remaining handlers still run.
- The default handler logs `full_message` when `$DEBUG`, `WURK_DEBUG`, or the
  logger is at `DEBUG`; otherwise `detailed_message`. `RedisClient::Error` and
  `ConnectionPool::TimeoutError` are logged at `WARN`, everything else at
  `INFO`.

### `config.death_handlers`

Called when a job exhausts its retries and moves to the dead set.
**Signature: `(job_hash, exception)`** — the job hash is the parsed job JSON
(string keys: `"class"`, `"args"`, `"jid"`, …).

```ruby
Wurk.configure_server do |config|
  config.death_handlers << ->(job, ex) do
    PagerDuty.trigger("#{job['class']} died: #{ex.message}", job_id: job["jid"])
  end
end
```

Fired from `JobRetry` when retries are exhausted or `sidekiq_retry_in` returns
`:discard`, and from `DeadSet#kill` when `notify: true`. A raising death handler
is routed to the error handlers and does not abort the rest of the chain.

---

## Lifecycle events

`config.on(event) { … }`. The event must be one of
`Wurk::Configuration::LIFECYCLE_EVENTS` — anything else raises `ArgumentError`,
as does calling `on` without a block.

| Event | Fires | Where |
|---|---|---|
| `:startup` | Once, before processor threads spin up. Exceptions **re-raise** and abort boot. In a swarm it fires in each child (after `:fork`), not in the parent | `CLI#run`, `Embedded#run`, `Swarm::ChildBoot#run` |
| `:fork` | In each swarm child, after fork and after Wurk's own ActiveRecord/Redis reconnect, before `:startup`. Never in the parent; never in single-process or embedded mode | `Swarm::ChildBoot#run` |
| `:quiet` | On TSTP / dashboard-issued quiet, after managers stop fetching. LIFO (reverse registration order) | `Launcher#quiet` |
| `:shutdown` | During `stop`, while managers drain. LIFO | `Launcher#stop` |
| `:exit` | At the very end of `stop`, after the heartbeat is cleared. LIFO | `Launcher#stop` |
| `:heartbeat` | On the **first** successful beat, and again after recovery from a Redis partition | `Heartbeat#beat!` |
| `:beat` | Every beat (`BEAT_PAUSE = 10` seconds). **Not oneshot** — the only recurring event | `Heartbeat#beat!` |
| `:leader` | On every follower → leader transition | `Leader#acquire` |

All events except `:beat` are oneshot: the bucket is cleared after dispatch. In
a swarm each child clears its own forked copy, so siblings still fire theirs.

```ruby
Wurk.configure_server do |config|
  config.on(:fork)     { MyLib.reconnect! }              # your non-fork-safe sockets/threads
  config.on(:startup)  { Rails.logger.info "wurk up" }
  config.on(:quiet)    { StatsD.increment("wurk.quiet") }
  config.on(:shutdown) { MyMetrics.flush }
  config.on(:beat)     { MyMetrics.gauge("wurk.alive", 1) }
  config.on(:leader)   { Rails.logger.info "elected leader" }
end
```

Wurk already reconnects ActiveRecord and opens a fresh Redis pool in each child
— `:fork` is for *your* libraries only.

---

## Logging

The default logger is `Wurk::Logger.new($stdout)` at level `INFO`.

```ruby
Wurk.configure_server do |config|
  config.logger.level = Logger::WARN
  config.logger.formatter = Wurk::Logger::Formatters::JSON.new   # NDJSON for log aggregators
end
```

| Concern | Behavior |
|---|---|
| Destination | `$stdout`. Assign `config.logger = Wurk::Logger.new("/var/log/wurk.log")` for a file |
| Level | `INFO`. `DEBUG` via `-v` or `DEBUG_INVOCATION=1` |
| Formatter | `Formatters::Pretty` by default; `Formatters::WithoutTimestamp` when `DYNO` is set (Heroku already prefixes a timestamp); `Formatters::JSON` opt-in |
| Context | All three formatters read the thread-local `Wurk::Context`, so every line carries `jid`/`bid`/`tags` without threading a hash through |
| Per-job lines | `Wurk::JobLogger` emits start/done. Silence with `config[:skip_default_job_logging] = true`; swap the class with `config[:job_logger]`; choose which job keys reach the log context with `config[:logged_job_attributes]` (default `["bid", "tags"]`) |
| Log rotation | `SIGUSR2` reopens the log file. Send it to the swarm parent — it relays USR2 to every child, and each child calls `logger.reopen`. The standalone `wurk` process handles USR2 itself |

Pretty output, for reference:

```text
INFO  2026-07-20T12:00:00.000Z pid=421 tid=abc1 jid=9f8e7d: start
```

---

## Dashboard configuration

Dashboard-specific settings live on `config.web` (which is the process-wide
`Wurk::Web.config`, so `Wurk::Web.configure { |c| … }` and
`Sidekiq::Web.configure { |c| … }` reach the same object):

```ruby
Wurk.configure_server do |config|
  config.web.read_only = true
  config.web.read_only_message = "Production board — retries are handled by on-call."
end
```

`read_only` starts from `WURK_WEB_READ_ONLY == "1"` and accepts string values
(`""`, `"0"`, `"false"`, `"no"`, `"off"` mean off). Authorization hooks, Rack
middleware, and CSRF are covered in [authentication.md](authentication.md).

---

## Health checks

Off by default. Opt in and the launcher starts a thin TCP listener inside each
worker process:

```ruby
Wurk.configure_server do |config|
  config.health_check(port: 7433, bind: "0.0.0.0", ready_window: 30)
end
```

- `GET /live` → 200 while the process is not stopping.
- `GET /ready` → 200 only when Redis is reachable **and** a heartbeat fired
  within `ready_window` seconds.
- `port` must be `0..65535`, `ready_window` must be `> 0`, `bind` non-empty —
  all validated at call time.
- The listener starts last in the boot sequence and is closed during shutdown.

---

## Divergences from the Sidekiq spec

Everything above is verified against the implementation. Where Wurk's surface
differs from `docs/target/sidekiq-free.md`:

| Divergence | Detail |
|---|---|
| Extra lifecycle events | Wurk's `LIFECYCLE_EVENTS` adds `:fork` (Ent §7.4) and `:leader` (Ent §6) to the free-spec set |
| Extra default key | `:redis_error_handlers` is in `DEFAULTS`; there is no Sidekiq equivalent (`config.on_redis_error`) |
| Pool sizing | Spec: per-capsule pool = `concurrency`, internal = 10. Wurk: main pool = `max(concurrency + 5, 10)`, **plus** a dedicated fetch pool of `concurrency` and a dedicated web pool of `web_pool_size` |
| `reap_idle_redis_connections` | Not implemented. `:redis_idle_timeout` is accepted (it is in `DEFAULTS`) but never consumed |
| `Config#redis_info` / `#to_json` | Not implemented on the configuration object. `Wurk::RedisPool#info` returns parsed `INFO` merged with the pool's `size`/`available` |
| `:max_iteration_runtime` | Accepted for drop-in compatibility; not consumed by `Wurk::IterableJob` |
| `thread_priority` | Stored and readable (default `-1`) but not applied to worker threads |
| `USR2` | Spec marks it "Pro only". In Wurk it always reopens logs, and the swarm parent relays it to children |
| Fetch mode | There is no "basic fetch". The default fetcher is always the reliable `BLMOVE` fetcher, so `config.super_fetch!` exists only so a Pro initializer drops in unchanged. `config.reliable_scheduler!` still does real work — keep it |
| `WURK_PRELOAD_APP` | Sidekiq's `SIDEKIQ_PRELOAD_APP` defaults to off *and* controls whether the app loads in the parent. Wurk's swarm always loads the app entrypoint in the parent (children inherit it); this flag toggles only the extra Rails `eager_load!` |
| YAML `:strict` | Silently dropped — strict fetch was removed in Sidekiq 8.x |

---

## Related

- [Migrating from Sidekiq](migrate-from-sidekiq.md) — the one-line swap, and
  §2 on concurrency vs parallelism.
- [Running Wurk](running.md) — runners, signals, and process layout.
- [Deployment](deployment.md) — production topology and rollout.
- [Authentication & authorization](authentication.md) — dashboard gating.
