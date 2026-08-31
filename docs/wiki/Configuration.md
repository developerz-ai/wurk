# Configuration

One initializer configures everything. `Wurk.configure_server` runs in worker processes, `configure_client` in anything that only enqueues — both are aliased from `Sidekiq.configure_server` / `Sidekiq.configure_client`.

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL") }
  config.concurrency = 5                 # threads per process
  config.queues = %w[critical default low]
  config.on(:startup) { Metrics.boot! }
end

Wurk.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL") }
end
```

`Wurk::Configuration` is hash-like (`config[:key]`, `fetch`, `dig`, `merge!`) as well as accessor-driven, because third-party gems reach for it that way.

## Precedence — Ruby wins

```text
Ruby (configure_server) > CLI flags > YAML env overlay > YAML top-level
                        > RAILS_MAX_THREADS (concurrency only) > DEFAULTS
```

Ruby wins because the initializer runs *last*, after the CLI has parsed flags and booted your app. `config.concurrency = 10` in an initializer beats `wurk -c 4` — same as Sidekiq. If you want the flag to win, read the env var yourself in the initializer.

## The knobs you will actually set

| Option | Default | Meaning |
|---|---|---|
| `concurrency` | `5` | Threads per worker process |
| `queues` | `["default"]` | Ordered/weighted queue list |
| `timeout` | `25` | Seconds in-flight jobs get on shutdown (`-t`) |
| `dead_max_jobs` | `10_000` | Dead-set trim ceiling |
| `dead_timeout_in_seconds` | 180 days | Dead-entry age trim |
| `error_handlers` / `death_handlers` | seeded / `[]` | `(ex, ctx, cfg)` and `(job, ex)` callables |
| `on(:startup\|:quiet\|:shutdown\|:heartbeat\|:leader\|…)` | — | Lifecycle hooks |

Processes are **not** in that table: process count is `WURK_COUNT`, an env var with no Ruby equivalent, because Sidekiq never forked and there is nothing to be compatible with.

## Environment variables worth memorising

| Variable | Effect |
|---|---|
| `REDIS_URL` | Default `redis://localhost:6379/0` |
| `WURK_COUNT` (`SIDEKIQ_COUNT`) | Swarm children. Whole = count, fractional = CPU multiplier, floor 1. Default `Etc.nprocessors` |
| `WURK_MAXMEM_MB` (`SIDEKIQ_MAXMEM_MB`) | RSS ceiling; parent TERMs and respawns the child. Unset = off |
| `WURK_DISABLED=1` | Skip server mode and swarm boot in a Rails host |
| `WURK_WEB_READ_ONLY=1` | Boot the dashboard read-only |
| `RAILS_MAX_THREADS` | Fallback concurrency when neither CLI nor YAML set it |

`WURK_*` is native, `SIDEKIQ_*` is the alias, and native is checked first.

**Gotchas.** There is no `WURK_CONCURRENCY` — threads are `config.concurrency` / `-c` / `RAILS_MAX_THREADS`. `WURK_COUNT`, `WURK_DISABLED`, `WURK_PRELOAD*` and `WURK_LEADER` are read at their point of use and are **outside** the precedence chain above; nothing in Ruby overrides them. And `max_iteration_runtime` and `redis_idle_timeout` are accepted for drop-in compatibility but not consumed.

Every option, every `ENV` read in `lib/`, YAML layout, CLI flags, pool sizing, capsules, and topology: **[docs/configuration.md](https://github.com/developerz-ai/wurk/blob/main/docs/configuration.md)**.
