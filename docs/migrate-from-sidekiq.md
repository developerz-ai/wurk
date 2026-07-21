# Migrating from Sidekiq to Wurk

Wurk is a clean-room, **wire-compatible** drop-in for Sidekiq + Sidekiq Pro + Sidekiq
Enterprise: the same Redis key schema, the same job JSON, and the same Ruby DSL. In
the common case the migration is a one-line `Gemfile` change — your existing jobs,
batches, limiters, cron entries, and live Redis data keep working untouched, and the
Pro/Enterprise features ship in the same free gem with no license check.

This guide covers what stays the same, the two knobs that surprise people
(parallelism vs concurrency), how to run a dedicated worker, the third-party gem
mappings, and a one-page cutover.

- **Authoritative API surface:** [`docs/target/sidekiq-free.md`](target/sidekiq-free.md) ·
  [`sidekiq-pro.md`](target/sidekiq-pro.md) · [`sidekiq-ent.md`](target/sidekiq-ent.md)
- **Generated API reference (YARD):** <https://developerz-ai.github.io/wurk/api/>
- **Why this is legal:** [`docs/clean-room.md`](clean-room.md)

> Verified against Wurk's Sidekiq-compat layer (`lib/wurk/compat.rb`), which mirrors
> Sidekiq **8.1.x**. Requires **Ruby ≥ 3.2** and **Redis ≥ 7.0**. On JRuby /
> TruffleRuby / Windows, Wurk falls back to threads-only mode (no fork),
> behaviorally equivalent to stock Sidekiq.

---

## TL;DR — flip the switch

```diff
  # Gemfile
- gem "sidekiq"
- gem "sidekiq-pro"        # if you had them
- gem "sidekiq-ent"
+ gem "wurk"
```

```bash
bundle install
```

That's it for code. Every public `Sidekiq::*` name resolves to its Wurk
implementation (`Sidekiq::Worker`, `Sidekiq::Job`, `Sidekiq::Batch`,
`Sidekiq::Limiter`, `Sidekiq.configure_server`, `Sidekiq::Client`, …), so your jobs,
initializers, and `sidekiq_options` keep compiling as-is.

The dashboard is a mountable Rails engine (precompiled — no Node needed):

```ruby
# config/routes.rb
mount Wurk::Engine => "/wurk"     # replaces `mount Sidekiq::Web => "/sidekiq"`
```

Optionally scaffold an initializer:

```bash
bin/rails g wurk:install          # writes config/initializers/wurk.rb
```

**Because the Redis schema is identical, a rolling deploy is safe** — Sidekiq and Wurk
processes can run against the same Redis during cutover, each picking up the other's
enqueued jobs. Roll back by reverting the `Gemfile` line; no data migration either way.

> ⚠️ **The one thing to size before you ship:** Wurk forks one worker process *per CPU
> core* by default, each running its own thread pool — so a single Sidekiq process
> becomes N processes on the same box. Read [§2](#2-concurrency-vs-parallelism-read-this)
> before the first production deploy; it's the only behavioral surprise in the swap.

---

## 1. Configuration: `Sidekiq.configure_server` ↔ `Wurk.configure_server`

The configuration block is identical, and `Sidekiq.configure_server` /
`Sidekiq.configure_client` are aliased to the Wurk methods — so existing initializers
need **no change**. Written natively:

```ruby
# Sidekiq                                 # Wurk (Sidekiq.* aliases also work)
Sidekiq.configure_server do |config|      Wurk.configure_server do |config|
  config.redis = { url: ENV["REDIS_URL"] }  config.redis = { url: ENV["REDIS_URL"] }
  config.concurrency = 10                    config.concurrency = 10
  config.queues = %w[critical default]       config.queues = %w[critical default]
end                                        end
```

Config options verified identical (`lib/wurk/configuration.rb`):

| Option | Notes |
|---|---|
| `concurrency` | threads per worker process (default `5`) |
| `queues` | ordered/weighted queue list |
| `redis = { url:, … }` | defaults to `ENV["REDIS_URL"]` → `redis://localhost:6379/0` |
| `logger`, `logger =` | standard `Logger` |
| `timeout` | job + shutdown grace seconds (default `25`) |
| `error_handlers`, `death_handlers` | arrays of callables |
| `client_middleware` / `server_middleware` | same `Chain#add/remove/insert_before` API |
| `on(:startup\|fork\|quiet\|shutdown\|exit\|heartbeat\|beat\|leader)` | lifecycle hooks |
| `capsule(name) { … }` | multi-queue capsules (Sidekiq 7+) |
| `periodic { \|mgr\| mgr.register(...) }` | cron jobs (Enterprise parity, free) |

> ℹ️ **`config.on(:fork)`** fires in each swarm child after fork — Wurk already
> reconnects DB/Redis for you (it closes parent connections before forking and each
> child opens a fresh pool), so you only need a fork hook for *your own* non-fork-safe
> libraries (sockets, threads). It does not fire in single-process (non-swarm) mode.

---

## 2. Concurrency vs parallelism (read this)

This is the **single biggest difference** from Sidekiq, and the #1 source of
migration surprises. Sidekiq runs one process with a thread pool. Wurk runs **a swarm
of forked processes, each with its own thread pool**, for real CPU parallelism on
MRI (the GIL means threads alone can't parallelize Ruby CPU work).

Two independent knobs:

| Knob | What it controls | How to set it | Default |
|---|---|---|---|
| **Parallelism** | Number of forked **worker processes** (real OS processes, true CPU parallelism) | `WURK_COUNT` (or the `SIDEKIQ_COUNT` alias) env var | **CPU core count** (`Etc.nprocessors`) |
| **Concurrency** | **Threads per process** (Sidekiq-style; great for IO-bound, GIL-bound for CPU) | `config.concurrency`, CLI `-c`, YAML `:concurrency`, or `RAILS_MAX_THREADS` | `5` |

> There is **no `WURK_CONCURRENCY` env var.** Threads-per-process is `config.concurrency`
> / `-c` / `RAILS_MAX_THREADS` (the same env knob Sidekiq honors). `WURK_COUNT` is the
> *new* knob — it has no Sidekiq equivalent because Sidekiq never forks.

> ⚠️ **`WURK_COUNT` only applies to the forking runners** — the Rails engine's
> auto-boot swarm and the standalone `bundle exec wurkswarm` (alias `sidekiqswarm`).
> Plain `bundle exec wurk` is a **single process** (one thread pool, like `sidekiq`);
> it ignores `WURK_COUNT`. Use `wurkswarm` when you want multi-process parallelism
> outside Rails. See [§3](#3-running-a-worker-process).

### Total in-flight jobs = `WURK_COUNT × concurrency`

A whole-number `WURK_COUNT` is an absolute process count; a fractional value is a CPU
multiplier (`WURK_COUNT=0.5` → half the cores, rounded). The result is floored at 1.

```text
16-core box, defaults:   16 processes × 5 threads  = 80 jobs in flight at once
                                                     + 16 separate DB connection pools
```

**That last line is the foot-gun.** Each forked process opens its own DB pool, its
own Redis pool, and carries its own memory footprint. A Sidekiq box that comfortably
ran `concurrency: 25` in one process can exhaust your Postgres `max_connections` or
your RAM the moment it becomes 16 processes × 25 threads = 400 connections.

### Worked example: mapping a Sidekiq `concurrency: 10` app

Your Sidekiq process ran 10 threads = 10 jobs in flight, 10 DB connections.

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.concurrency = 5        # threads per process
end
```

```bash
# Pick the process count to land near your old in-flight number. WURK_COUNT
# drives the forking runner (wurkswarm), or the Rails engine's auto-boot swarm:
WURK_COUNT=2  bundle exec wurkswarm   # 2 × 5  = 10 jobs in flight (matches Sidekiq, now on 2 cores)
WURK_COUNT=4  bundle exec wurkswarm   # 4 × 5  = 20 in flight — 2× the throughput, 4× the CPU parallelism

bundle exec wurk -c 10                # or stay single-process (no fork) with 10 threads, Sidekiq-like
```

In a Rails app you don't run either binary — the engine auto-boots the swarm and
reads `WURK_COUNT` itself; set the env var on the worker role.

**Size your database pool for the per-process thread count, then check the total.**
Each process needs `pool >= concurrency` in `database.yml`:

```yaml
# config/database.yml
production:
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", 5).to_i %>   # per-process; must cover concurrency
```

Then verify the whole box fits: **`WURK_COUNT × pool ≤ your DB's spare connections`**.
On the 16-core default that's 16 × 5 = 80 connections from one host — size
`max_connections` (or PgBouncer) accordingly, or cap `WURK_COUNT`.

> **Rule of thumb:** start with `WURK_COUNT` = cores you want to dedicate to jobs and
> `concurrency` = 5 for IO-bound work. Raise `concurrency` for IO-heavy jobs (HTTP,
> Redis, slow SQL); raise `WURK_COUNT` for CPU-heavy jobs. Always re-check the DB-pool
> and memory math after either change.

---

## 3. Running a worker process

### Dedicated worker: `wurk` vs `wurkswarm`

The gem ships two standalone runners (and an alias) — there is **no `sidekiq`
binary**, so update any `bundle exec sidekiq` invocation, Procfile line, and
systemd/Capistrano unit:

| Binary | What it does | Sidekiq equivalent |
|---|---|---|
| `bundle exec wurk` | One process, one thread pool | `sidekiq` |
| `bundle exec wurkswarm` | Forks `WURK_COUNT` worker children from one preloaded parent — fork-based real parallelism | `sidekiqswarm` |

`sidekiqswarm` is shipped as an alias for `wurkswarm`, so an existing Enterprise
invocation drops in unchanged. **Use `wurkswarm` for a multi-process worker host**
(it's the only way to get fork-based parallelism without Rails); use `wurk` for a
single-process worker. Both take the familiar flags (`-c` concurrency, `-q` queue,
`-r` require, `-t` timeout, `-e` environment, `-C` config), read a YAML config with
`-C path`, and auto-discover `config/wurk.yml` then `config/sidekiq.yml` (`.erb`
supported). The YAML structure matches Sidekiq's `sidekiq.yml`.

```bash
bundle exec wurkswarm -C config/wurk.yml -e production   # forked swarm (real parallelism)
bundle exec wurk      -C config/wurk.yml -e production    # single process
```

Neither runner loads the Rails engine (the dashboard) — by design, so a worker host
stays lean. They do fully boot your Rails app (`-r`/the environment) so your jobs and
models are available.

> ✅ **ActiveJob works standalone.** If your app uses
> `config.active_job.queue_adapter = :wurk` (or `:sidekiq`), the standalone CLI now
> defines the adapter *before* the Rails environment loads, so a dedicated worker
> process boots cleanly. (Earlier builds raised `uninitialized constant WurkAdapter`
> in standalone mode — fixed in [#253](https://github.com/developerz-ai/wurk/issues/253).)

For an example systemd unit and the Capistrano / deploy signal dance (replacing
`capistrano-sidekiq`), see [`docs/deployment.md`](deployment.md). A `Procfile`
worker line is simply:

```procfile
worker: bundle exec wurkswarm -e production
```

### Clustered Puma + the embedded swarm (important)

When you mount the engine, the railtie **auto-starts an embedded swarm inside every
non-console Rails process** (unless `WURK_DISABLED=1`, Rails console, or the Rails
test env). Under **clustered Puma** (`workers > 0`) that means **every Puma worker
forks its own Wurk swarm** — N Puma workers × `WURK_COUNT` children = a lot of
duplicate worker processes you didn't intend, all fetching the same queues.

**The fix: run workers in a dedicated process and disable the embedded swarm on the
web role.**

```bash
# Web dyno / Puma role — serve HTTP only, no jobs:
WURK_DISABLED=1 bundle exec puma -C config/puma.rb

# Worker dyno / role — run the jobs (wurkswarm for multi-process parallelism):
bundle exec wurkswarm -e production
```

This mirrors the standard Sidekiq topology (Puma for web, a separate `sidekiq`
process for jobs) — you just set `WURK_DISABLED=1` on web so the engine mount keeps
serving the dashboard without also forking workers. Leave the embedded swarm on only
if you intentionally want web processes to also run jobs (single-dyno / hobby setups).

---

## 4. Redis key layout: identical, no namespace

Wurk reads and writes the **exact same keys** as Sidekiq OSS (`lib/wurk/keys.rb`),
with **no global namespace/prefix** (matching Sidekiq OSS). Job payloads are **JSON**
(never MessagePack), with args stored as-is.

| Key | Type | Same as Sidekiq? |
|---|---|---|
| `queue:<name>` | LIST | ✅ identical |
| `queues` | SET | ✅ identical |
| `paused` | SET | ✅ identical |
| `schedule`, `retry`, `dead` | ZSET (score = float Unix seconds) | ✅ identical |
| `processes` + per-process HASH | SET/HASH | ✅ identical |
| `stat:processed[:<date>]`, `stat:failed[:<date>]` | STRING | ✅ identical |
| `b-<bid>*`, `batches` | HASH/SET/ZSET | ✅ Pro batch schema |
| `loops:<lid>`, `periodic` | HASH/SET | ✅ Enterprise periodic schema |

Job JSON fields are the Sidekiq set: `class, args, queue, jid, created_at,
enqueued_at, retry, retry_count, failed_at, retried_at, error_class, error_message,
error_backtrace` (base64+zlib), plus the optional Pro/Ent fields (`bid, tags,
expiry, …`). The dead set is trimmed by `dead_max_jobs` (default 10,000) and
`dead_timeout_in_seconds` (default 180 days), same as Sidekiq.

**Implication:** a mixed fleet (some Sidekiq, some Wurk) on one Redis is safe, and
the Sidekiq web UI / `redis-cli` introspection you already use keeps working.

---

## 5. `sidekiq_options` mapping

Define jobs exactly as before — `include Sidekiq::Job` (or `Sidekiq::Worker`) and
`sidekiq_options`. Enqueue with `perform_async` / `perform_in` / `perform_at` /
`perform_bulk` / `set(...)`. Defaults: `{ retry: true, queue: "default" }`.

| `sidekiq_options` key | Supported | Behavior in Wurk |
|---|---|---|
| `queue:` | ✅ | routes to `queue:<name>`; default `"default"` |
| `retry:` (`true` / `false` / `N`) | ✅ | `true` → up to 25 attempts; `N` → max attempts; `false` → no retry (→ dead set unless `dead: false`) |
| `dead:` (`true` / `false`) | ✅ | `false` skips the morgue on exhaustion (discard instead). Default `true` |
| `backtrace:` (`true` / `N`) | ✅ | store backtrace lines on failure (base64+zlib), Sidekiq-compatible |
| `expires_in:` | ✅ (Pro, free) | drop the job before `perform` if it sits past the window; counts as processed |
| `retry_queue:`, `retry_for:` | ✅ | route retries to another queue / cap total retry duration |
| `tags:` | ✅ | array of strings; surfaced in the dashboard + logs |
| `batch` | ✅ (Pro, free) | not a `sidekiq_options` key — `bid` is stamped automatically inside `Sidekiq::Batch#jobs { … }`; access via `#bid` / `#batch` |
| `pool:` | ✅ | selects the client Redis pool; stripped from the stored payload |
| `lock:` | ⚠️ not native | Wurk's native uniqueness uses `unique_for:` / `unique_until:` (see [§6](#6-third-party-gem-mappings)). The `sidekiq-unique-jobs` gem and its `lock:` option also run against Wurk in the ecosystem CI suite |

Custom retry hooks are unchanged: `sidekiq_retry_in { |count, ex, msg| … }` and
`sidekiq_retries_exhausted { |msg, ex| … }`. The retry backoff formula matches
Sidekiq: `count**4 + 15 + rand(10 * (count + 1))` seconds.

### Pro / Enterprise options (free in Wurk)

- **Unique jobs:** enable with `Sidekiq::Enterprise.unique!`, then
  `sidekiq_options unique_for: 10.minutes, unique_until: :success` (or `:start`).
  *(This is Enterprise's API — not the `sidekiq-unique-jobs` gem's `lock:` DSL; see
  [§6](#6-third-party-gem-mappings) for the gem mapping.)*
- **Encryption:** `Sidekiq::Enterprise::Crypto.enable(active_version: 1) { |v| key }`,
  then `sidekiq_options encrypt: true` (the last arg is encrypted).
- **Batches:** `Sidekiq::Batch.new` with `on(:success/:complete/:death)`, nesting,
  and `Sidekiq::Batch::Status`.
- **Rate limiters:** `Sidekiq::Limiter.concurrent/bucket/window/leaky/points`.

---

## 6. Third-party gem mappings

Wurk ships native replacements for the most common add-on gems, so you can **drop the
gem** and use the built-in feature — or keep the gem, since its upstream test suite is
run against Wurk in the [`ecosystem` CI job](../.github/workflows/ecosystem.yml). The
native path is recommended (fewer dependencies, first-class dashboard support).

### `sidekiq-cron` → native periodic jobs

Wurk has Enterprise-grade periodic jobs built in. Register them in a `config.periodic`
block at boot. By design there is **no `Sidekiq::Cron::Job` shim** ([#204](https://github.com/developerz-ai/wurk/issues/204));
real Sidekiq never defined that constant, and faking it would break the drop-in
contract.

```ruby
# sidekiq-cron (old):                       # Wurk (native):
# config/schedule.yml + Sidekiq::Cron::Job   Wurk.configure_server do |config|
#                                              config.periodic do |mgr|
#                                                mgr.register("*/5 * * * *", ReportJob)
#                                                mgr.register("0 0 * * *", NightlyJob, tz: "UTC")
#                                              end
#                                            end
```

`mgr.register(cron, JobClass, **opts)` takes a standard 5-field cron string and the
worker class; `tz:` sets the timezone. Periodic state lives in the `periodic` / `loops:<lid>`
Redis keys and is visible in the dashboard.

### `sidekiq-unique-jobs` → native `unique_for:` / `unique_until:`

Activate Enterprise uniqueness once, then declare it per worker:

```ruby
# config/initializers/wurk.rb
Sidekiq::Enterprise.unique!   # required to activate the unique middleware

class ChargeJob
  include Sidekiq::Job
  sidekiq_options unique_for: 600,            # seconds (or 10.minutes); the lock TTL
                  unique_until: :success      # :success (default) | :start
end
```

Mapping from `sidekiq-unique-jobs`:

| `sidekiq-unique-jobs` | Wurk native |
|---|---|
| `lock: :until_executed` | `unique_until: :success` (lock held through retries, released on success) |
| `lock: :until_executing` / `:while_executing` | `unique_until: :start` (server middleware releases the lock when the job starts) |
| `lock_ttl` / `lock_timeout` | `unique_for: <int seconds>` (also accepts an `ActiveSupport::Duration`) |
| `lock_args_method` / custom uniqueness args | define `self.sidekiq_unique_context(job)` on the worker, returning any JSON-serializable value |

> ⚠️ Unique jobs and encryption are **mutually exclusive on the same worker** — each
> encryption produces different ciphertext, which defeats the uniqueness digest.

### Quick reference — other ecosystem gems

These run their own upstream suites against Wurk in CI; most work unchanged because
they only touch the Sidekiq API surface and Redis keys Wurk already mirrors.

| Gem | Status on Wurk | Notes |
|---|---|---|
| `sidekiq-scheduler` | ✅ works unchanged | uses the standard schedule ZSET |
| `sidekiq-status` | ✅ works unchanged | rides the standard job lifecycle + middleware |
| `sidekiq-failures` | ✅ works unchanged | reads the standard `retry`/`dead` sets |
| `sidekiq-throttled` | ✅ works unchanged | client/server middleware contract is identical |
| `sidekiq-cron` | ⚠️ prefer native | works in CI, but native `config.periodic` is recommended (no `Sidekiq::Cron::Job` constant) |
| `sidekiq-unique-jobs` | ⚠️ prefer native | works in CI, but native `unique_for:` is recommended |

---

## 7. Known incompatibilities — what *not* to expect

Wurk aims for 100% drop-in. A couple of Sidekiq Pro-isms simply no-op or alias
(items 1–2 — there to reassure, not to fix); the rest are genuine differences worth
knowing. Hit something on a real migration that isn't listed here? **Please open an
issue** — that feedback is part of the v1.0.0 acceptance gate for this guide.

1. **`config.super_fetch!` does nothing** (accepted no-op). Wurk's fetcher is
   *always* reliable (atomic `BLMOVE` to a per-process private list, with orphan
   reclamation), so a Sidekiq Pro initializer drops in unchanged — the call just
   no-ops rather than toggling anything.

   **`config.reliable_scheduler!` is not a no-op — keep it.** The default
   `scheduled_enq` pops due jobs then pushes them, which has a job-loss window if
   the process dies in between; `reliable_scheduler!` swaps in the atomic
   promoter that closes it. See [`docs/reliability.md`](reliability.md).
   (`Wurk::Client.reliable_push!` also exists for client-side buffering during a
   Redis outage.)
2. **`Sidekiq::Pro::Web` works** — it aliases the same dashboard as `Sidekiq::Web`,
   so `mount Sidekiq::Pro::Web` (or `Sidekiq::Web`, or `Wurk::Engine`) all resolve to
   the wurk dashboard.
3. **`config.workers` / `config.shutdown_timeout` are not Configuration setters.**
   Use `config.concurrency` for threads-per-process and `config[:timeout]` for the
   shutdown grace; process/fork count is governed by `WURK_COUNT` and the swarm
   topology (`config.topology = Wurk::Topology.flat(count:, queues:, concurrency:)`),
   not a `workers=` accessor. See [§2](#2-concurrency-vs-parallelism-read-this).
4. **Unique jobs + encryption are mutually exclusive on the same worker** — each
   encryption produces different ciphertext, which defeats the uniqueness digest.
5. **No Redis namespacing** in the free gem (same as Sidekiq OSS). One logical
   Sidekiq dataset per Redis.
6. **Ruby ≥ 3.2, Redis ≥ 7.0** required (Sidekiq 8 allows slightly older Ruby).
7. **Fork-based by default.** On MRI, Wurk forks worker processes for real
   parallelism (load your app *before* the fork; the swarm closes parent
   connections pre-fork and children reconnect). On JRuby / TruffleRuby / Windows it
   falls back to threads-only, behaviorally equivalent to stock Sidekiq.
8. **`Sidekiq.pro?` and `Sidekiq.ent?` return `false`** — Wurk is free and reports
   itself as OSS, even though the Pro/Ent features are present. Don't gate behavior on
   these predicates.

---

## 8. Cutover checklist

1. **Swap the gem** — replace `sidekiq` (+ `sidekiq-pro` / `sidekiq-ent`) with `wurk`
   in the `Gemfile`; `bundle install`.
2. **Size parallelism × concurrency** — decide `WURK_COUNT` (processes) and
   `concurrency` (threads), then check your DB pool and memory against
   `WURK_COUNT × concurrency`. See [§2](#2-concurrency-vs-parallelism-read-this). This
   is the only step that needs real thought.
3. **Keep your config as-is** — `config.super_fetch!` is an accepted no-op
   (already the default) and `config.reliable_scheduler!` still does real work, so
   there's nothing to strip out either way.
4. **Re-point the dashboard route** — `mount Wurk::Engine => "/wurk"` (gate it behind
   your app auth — see [`docs/authentication.md`](authentication.md)).
5. **Split web from workers** — run a dedicated `bundle exec wurkswarm` process and set
   `WURK_DISABLED=1` on the web role so clustered Puma doesn't fork duplicate swarms.
   See [§3](#3-running-a-worker-process). Deploying under systemd/Capistrano? See
   [`docs/deployment.md`](deployment.md).
6. **Map any add-on gems** — swap `sidekiq-cron` → `config.periodic` and
   `sidekiq-unique-jobs` → `unique_for:` if you want the native path. See
   [§6](#6-third-party-gem-mappings).
7. **Verify on the same Redis** — enqueue a test job, watch it run, and confirm the
   dashboard + your existing `redis-cli` checks look normal. Because the schema is
   shared, you can roll one process at a time.
8. **Roll back anytime** — revert the `Gemfile` line. No schema changes were made.

---

*Found a blocker not covered here? File an issue at
<https://github.com/developerz-ai/wurk/issues> — closing the loop on real migrations
is how this guide earns its v1.0.0 sign-off.*
