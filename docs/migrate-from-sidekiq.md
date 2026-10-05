# Migrating from Sidekiq to Wurk

Wurk is an independently implemented, **wire-compatible** drop-in for Sidekiq + Sidekiq Pro + Sidekiq
Enterprise: the same Redis key schema, the same job JSON, and the same Ruby DSL. In
the common case the migration is a one-line `Gemfile` change — your existing jobs,
batches, limiters, cron entries, and live Redis data keep working untouched, and the
Pro/Enterprise features ship in the same free gem with no license check.

This guide covers what stays the same, the two knobs that surprise people
(parallelism vs concurrency), how to run a dedicated worker, the third-party gem
mappings, a one-page checklist, and the [production cutover](#9-production-cutover)
playbook for moving a live Sidekiq Pro/Enterprise fleet.

> **Before you migrate.** The API this guide teaches you to keep is *Sidekiq's*,
> funded by its paid tiers and human-maintained. Moving to Wurk is a bet on a
> different maintenance model — AI-first, which is what makes the same surface
> free software (see the README's *Why Wurk exists*) — not a verdict on Sidekiq.
> If you want a commercial support contract behind your queue, staying on
> Pro/Enterprise is a perfectly good answer. Wurk is independent and not
> affiliated with or endorsed by Sidekiq or its maintainers.

- **Authoritative API surface:** [`docs/target/sidekiq-free.md`](target/sidekiq-free.md) ·
  [`sidekiq-pro.md`](target/sidekiq-pro.md) · [`sidekiq-ent.md`](target/sidekiq-ent.md)
- **Generated API reference (YARD):** <https://developerz-ai.github.io/wurk/api/>
- **Why this is legal:** [`docs/compatibility.md`](compatibility.md)

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

> ⚠️ **Do you depend on any `sidekiq-*` add-on gem?** Almost every one (sidekiq-cron,
> sidekiq-unique-jobs, sidekiq-status, …) declares `add_dependency "sidekiq"`, so
> `bundle install` quietly pulls **real Sidekiq back in** next to Wurk and
> `require "sidekiq"` loads a broken hybrid of the two. Either drop the add-on for
> Wurk's native equivalent ([§6](#6-third-party-gem-mappings)), or satisfy the
> dependency with Wurk's `sidekiq` shim gem — a git-only gem, never published to
> rubygems.org:
>
> ```ruby
> gem "wurk"
> gem "sidekiq", github: "developerz-ai/wurk", glob: "ecosystem/sidekiq-shim/*.gemspec"
> gem "sidekiq-cron"   # any add-on you keep
> ```
>
> Check with `bundle info sidekiq`: its path must point into the wurk git
> checkout (`ecosystem/sidekiq-shim`), not a released `sidekiq-x.y.z` gem. Details:
> [`ecosystem/sidekiq-shim/README.md`](../ecosystem/sidekiq-shim/README.md).

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

**Because the Redis schema is identical, there is no data migration** — Wurk picks up
the queues, schedules, retries, batches and periodic loops Sidekiq left in Redis, and
going back is the same move in reverse. What is *not* proven yet is running Sidekiq
and Wurk worker processes against one Redis **at the same time**: no test runs a mixed
fleet, and two places are known to need care (Wurk's private lists are a shape stock
Sidekiq never reclaims, and Enterprise leader election and unique locks have not been
exercised across the two). So the supported production path is a **drain cutover** —
stop Sidekiq's workers, then start Wurk's — not a rolling mix. The procedure, with the
exact commands, is [§9](#9-production-cutover).

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
| `redis = { url:, … }` | defaults to `ENV["REDIS_URL"]` → `redis://localhost:6379/0`; see the key notes below |
| `logger`, `logger =` | standard `Logger` |
| `timeout` | job + shutdown grace seconds (default `25`) |
| `error_handlers`, `death_handlers` | arrays of callables |
| `client_middleware` / `server_middleware` | same `Chain#add/remove/insert_before` API |
| `on(:startup\|fork\|quiet\|shutdown\|exit\|heartbeat\|beat\|leader)` | lifecycle hooks |
| `capsule(name) { … }` | multi-queue capsules (Sidekiq 7+) |
| `periodic { \|mgr\| mgr.register(...) }` | cron jobs (Enterprise parity, free) |

### `config.redis` keys

The hash is Sidekiq's, but it isn't verbatim redis-client: Sidekiq normalized it
internally before handing it over, and Wurk does the same translation so your existing
initializer needs no edit.

| Sidekiq key | Wurk |
|---|---|
| `url`, `db`, `username`, `password`, `ssl`, `ssl_params`, `driver`, `sentinels`, … | ✅ pass through |
| `size`, `pool_timeout`, `pool_name` | ✅ pool-structural, consumed by Wurk |
| `network_timeout` / `timeout` | ✅ fanned out to `connect_timeout` / `read_timeout` / `write_timeout` — Wurk splits them by default, and an explicitly-set one wins |
| `master_name` | ✅ → `name`; with `sentinels:` the pool is built via `RedisClient.sentinel` |
| `logger`, `cluster_safe` | ✅ accepted and dropped (as Sidekiq does) |
| `namespace` | ❌ raises — Wurk has no namespacing (§4). Give it its own Redis database or instance |
| `nodes` | ❌ raises — Redis Cluster is unsupported |

Anything else redis-client would reject raises on assignment, naming the key.

> ⚠️ **Upgrade note (1.3.1).** Through 1.3.0 the hash was splatted straight into
> redis-client, so `network_timeout` (and the other Sidekiq-only spellings) raised
> `ArgumentError: unknown keyword`. The swarm parent doesn't build a pool, so this only
> killed the forked children — a Running pod with a passing liveness probe processing
> zero jobs. Fixed in 1.3.1 ([#283](https://github.com/developerz-ai/wurk/issues/283)).

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

Neither runner *starts* the Rails engine (the dashboard) — by design, so a worker host
stays lean: no engine initializers, no dashboard routes, no assets. They do fully boot
your Rails app (`-r`/the environment) so your jobs and models are available — and that
includes a `config/routes.rb` that mounts the dashboard, since `Wurk::Engine` resolves
on demand.

> ⚠️ **Upgrade note (1.3.1).** Through 1.3.0 that last part wasn't true: an app with
> `mount Wurk::Engine => "/wurk"` in its routes booted fine under `rails server` but
> died under `wurk` / `wurkswarm` with `uninitialized constant Wurk::Engine`, because
> the runners require `wurk` before Rails exists. Fixed in 1.3.1
> ([#282](https://github.com/developerz-ai/wurk/issues/282)) — no `require "wurk/rails"`
> in routes.rb needed.

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

**Implication:** Wurk reads what Sidekiq wrote, and the Sidekiq web UI / `redis-cli`
introspection you already use keeps working. One key family differs: Wurk names its
reliable-fetch private lists `queue:<q>|<host>|<pid>|<nonce>|<index>` (five segments,
the nonce disambiguates PID-namespace reuse), where Sidekiq Pro uses
`queue:<q>|<host>|<pid>|<index>`. Wurk reclaims Pro's shape; stock Sidekiq does not
reclaim Wurk's. That asymmetry is one reason a mixed fleet is not the supported path
yet — see [§9](#9-production-cutover).

Pro/Enterprise key formats (batches, `lmtr*` limiters, `unique:<digest>` locks,
`dear-leader`, `loops:<lid>`) are implemented against the documented spec in
[`docs/target/`](target/sidekiq-ent.md), not yet validated against a dump taken from a
real Pro/Enterprise deployment. The staging dry run in [§9](#9-production-cutover) is
how you close that gap for your own data before production.

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
| `track:` (`true` / `false`) | ➕ Wurk extra | opt into `Wurk::Status` — a `status:<jid>` row carrying state, progress, timings, result and error. Default `false`: a class that doesn't opt in writes nothing and costs nothing. Lifetime via `status_ttl` / `status_retention`. A worker that also sets `encrypt: true` records everything but the result — see [encryption](encryption.md#interactions) |
| `collapse:` (`{ policy: :debounce, wait:, max_wait: }` / `{ policy: :throttle, slot: }`) | ➕ Wurk extra | collapse repeat enqueues of one identity: **debounce** keeps the *last* payload and fires after `wait` seconds of quiet (capped at `max_wait` from the first enqueue), **throttle** admits one per epoch-aligned `slot` and drops the rest. `perform_async` returns `nil` for every debounced push and for a dropped throttled one; an admitted throttled push returns its jid as usual. The policy is stripped from the stored payload, so a promoted or retried job is enqueued rather than judged a second time. Mutually exclusive with `unique_for:`, rejected at class definition; not available on `perform_bulk` |
| `lock:` | ⚠️ not native | Wurk's native uniqueness uses `unique_for:` / `unique_until:` (see [§6](#6-third-party-gem-mappings)). The `sidekiq-unique-jobs` gem (and its `lock:` option) is **not tested** against Wurk yet — tracked in [`docs/idea/14-ecosystem-compat.md`](idea/14-ecosystem-compat.md) |

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
gem** and use the built-in feature. The native path is recommended: fewer
dependencies, first-class dashboard support, and it is what Wurk's own suite tests.

Keeping an add-on gem instead needs the `sidekiq` shim gem (see the warning under
[TL;DR](#tldr--flip-the-switch)). Only one add-on has its upstream suite run against
Wurk on every PR: **`sidekiq-cron`**, in the
[`ecosystem` CI job](../.github/workflows/ecosystem.yml) (harness in
[`test/ecosystem/`](../test/ecosystem/README.md)). Every other add-on below is
**untested** on Wurk — the pins researched and the known blockers are tracked in
[`docs/idea/14-ecosystem-compat.md`](idea/14-ecosystem-compat.md).

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

#### Moving a live sidekiq-cron schedule

sidekiq-cron keeps its schedule in Redis — `cron_jobs:<namespace>` SETs of
`cron_job:<namespace>:<name>` HASHes (one `cron_jobs` SET of `cron_job:<name>` on
releases before namespaces) — while Wurk's loops live in `periodic` / `loops:<lid>`.
Neither reads the other's keys, so the only way to double-fire a schedule is to run
both pollers at once, and the only way to lose one is to forget an entry. The
procedure:

1. **Inventory.** `bin/rails wurk:import:cron` reads every sidekiq-cron entry and
   prints what each becomes. It is a dry run: it writes nothing.

   ```text
   sidekiq-cron entries: 3 (2 importable, 1 skipped)

     import  default/nightly_report  "0 3 * * *" NightlyReportJob  -> lid 3f9c0e1a7b2d4c55 (new)
     import  default/sync  "*/10 * * * *" SyncJob  -> lid 8a1b2c3d4e5f6071 (new)
     skip    default/heartbeat  unsupported schedule "*/30 * * * * *" (...); Wurk takes a 5-field crontab or an @alias, not fugit seconds or natural language

   To keep these in code (recommended), paste into config/initializers/wurk.rb:

   Wurk.configure_server do |config|
     config.periodic do |mgr|
       mgr.register("0 3 * * *", "NightlyReportJob", label: "nightly_report", queue: "default", retry: true)
       mgr.register("*/10 * * * *", "SyncJob", label: "sync", queue: "default", retry: true)
     end
   end
   ```

2. **Choose where each entry lives.** Pasting the printed block into an initializer
   is the recommended home: the schedule is reviewed in pull requests and survives a
   Redis flush. Entries your app created at runtime (`Sidekiq::Cron::Job.create`)
   and does not want in code can go straight into Redis with
   `APPLY=1 bin/rails wurk:import:cron`. The printed block registers exactly the lid
   the import writes, so importing now and pasting that block unchanged later
   converges on one loop. Combining the two routes for one class is safe **only when
   both produce the same loop ID** (lid). The lid hashes the schedule, the class and
   every option (`args`, `queue`, `retry`, `label`, …), so the same schedule with
   different args or queue is a different loop. At boot, a process that registers a
   class in `config.periodic` prunes every other loop of that class, so an imported
   loop whose lid your code does not register is dropped
   ([periodic jobs](periodic-jobs.md#deploys-what-happens-when-a-schedule-changes)).
   Compare the `lid` the dry run prints with the **Cron** tab after deploying the code.
3. **Fix what was skipped.** The task skips, with the reason, anything a native loop
   cannot reproduce unchanged: fugit natural-language or seconds-field schedules,
   `date_as_argument`, and GlobalID-serialized args. It warns (and imports) when an
   ActiveJob `queue_name_prefix` or `symbolize_args` would not carry over. A trailing
   timezone (`0 5 * * * Europe/Paris`) becomes `tz:`; a `disabled` entry is imported
   paused; the entry's name becomes the loop's `label`.
4. **Remove the gem in the release that starts Wurk.** No process should run
   sidekiq-cron's poller next to Wurk's for the same entries. If you keep sidekiq-cron
   for a while (through the shim gem), don't import the entries it still owns.
5. **Verify, then clean up later.** After cutover the dashboard's **Cron** tab lists
   every loop with its next fire. The import never touches sidekiq-cron's keys, so
   a rollback still finds the schedule. Once you are past your rollback window:
   `redis-cli -u "$REDIS_URL" --scan --pattern 'cron_job*' | xargs -r -n 500 redis-cli -u "$REDIS_URL" UNLINK`.

Outside Rails the same task is available after `require "wurk/rake_tasks"` in your
`Rakefile`; it uses the Redis connection your client config points at.

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

#### Moving off sidekiq-unique-jobs during a cutover

There is no import for sidekiq-unique-jobs, by design. Its locks live under
`uniquejobs:*` with its own digest algorithm, Wurk's under `unique:<digest>`; they
are disjoint, and Wurk never reads or releases the gem's locks. Translating them
would be guesswork, and most of them are short-lived anyway.

What that means during the drain cutover:

- Jobs that were enqueued under a gem lock and are still sitting in a queue, in
  `schedule` or in `retry` run normally on Wurk. The gem's `lock*` fields in their
  payload are inert.
- A new enqueue under Wurk's `unique_for:` takes a fresh `unique:` lock, so it does
  not see a duplicate that was enqueued under the gem's lock before the cutover. Worst
  case: one extra run per identity, once, across the cutover.
- If even that is unacceptable for a class (payments, outbound messages), drain that
  class's scheduled and retry entries before the cutover, or make the job idempotent
  ([reliability](reliability.md#idempotency-is-yours)).
- Leftover gem locks do nothing once the gem is gone. Clean them up after the cutover:
  `redis-cli -u "$REDIS_URL" --scan --pattern 'uniquejobs:*' | xargs -r -n 500 redis-cli -u "$REDIS_URL" UNLINK`.

### `sentry-sidekiq` → native `Wurk::Sentry`

`sentry-sidekiq` declares `add_dependency "sidekiq"`, so without the shim gem
`bundle install` pulls real Sidekiq back in and `require "sidekiq"` loads a hybrid
of the two — and even with the shim its error reporting is wrong on Wurk (see
[docs/sentry.md](sentry.md)). Use the built-in integration instead — no extra gem:

```ruby
# Gemfile: keep sentry-ruby, drop sentry-sidekiq

# config/initializers/wurk.rb
require "wurk/sentry"

Wurk.configure_server do |config|
  Wurk::Sentry.install!(config)
end
```

It reports job failures **and** the worker-process errors that never become a
job failure. As on Sidekiq, every job failure also reaches
`config.error_handlers` (once, with the job's own exception and
`context: "Job raised exception"`), so a reporter wired only through
`error_handlers` — Honeybadger, Rollbar, Bugsnag, a custom notifier — keeps
working unchanged.

Only the terminal failure is reported (not all 25 retry attempts), job `args`
are never sent, and self-healing Redis/pool blips are filtered out of the fetch
loop. Full setup, options, and a `sentry-sidekiq` migration table:
[**docs/sentry.md**](sentry.md).

### Quick reference — other ecosystem gems

Keeping any of these requires the [`sidekiq` shim gem](../ecosystem/sidekiq-shim/README.md).
"Untested" means exactly that: nobody has run the gem's suite against Wurk, so treat it
as unknown and verify it in staging before production.

| Gem | Status on Wurk | Notes |
|---|---|---|
| `sidekiq-cron` | ✅ upstream suite runs on every PR · ⚠️ prefer native | pinned in `test/ecosystem/sidekiq-cron/PIN`; native `config.periodic` is still recommended (no `Sidekiq::Cron::Job` constant) |
| `sidekiq-unique-jobs` | ❓ untested · prefer native | native `unique_for:` is the supported path; harness tracked in `docs/idea/14-ecosystem-compat.md` |
| `sidekiq-status` | ❓ untested · known blocker | its web extension mutates `Sidekiq::WebHelpers`, which Wurk's SPA dashboard does not expose (see `docs/idea/14-ecosystem-compat.md`). Wurk's native `track:` (`Wurk::Status`, `status:<jid>`) is the supported path; the two use different keys and never read each other |
| `sidekiq-scheduler` | ❓ untested | prefer native `config.periodic` |
| `sidekiq-failures` | ❓ untested | the dashboard already shows the standard `retry`/`dead` sets |
| `sidekiq-throttled` | ❓ untested | it patches Sidekiq's fetch classes to requeue throttled jobs, and Wurk's reliable fetcher is not one of them; prefer native [rate limiting](rate-limiting.md) |
| `sentry-sidekiq` | ❌ don't | reports the wrong errors on Wurk even with the shim. Use [`Wurk::Sentry`](sentry.md) |

---

## 7. Known incompatibilities — what *not* to expect

Wurk aims for 100% drop-in. A couple of Sidekiq Pro-isms simply no-op or alias
(items 1–2 — there to reassure, not to fix); the rest are genuine differences worth
knowing. The complete, maintained list of every place Wurk deliberately behaves
differently from the spec is
[`docs/idea/parity-divergences.md`](idea/parity-divergences.md); the ones that matter
on cutover day are summarized in [§9](#behaviour-differences-to-know-before-cutover).
Hit something on a real migration that isn't listed? **Please open an issue** — real
migrations are what this guide is checked against.

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
9. **`sentry-sidekiq` cannot be installed** — its gemspec declares
   `add_dependency "sidekiq"`, so Bundler installs real Sidekiq alongside Wurk and
   `require "sidekiq"` loads a broken hybrid. Wurk ships its own integration:
   `require "wurk/sentry"` + `Wurk::Sentry.install!(config)`. See
   [`docs/sentry.md`](sentry.md).

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
7. **Rehearse on a copy of production Redis** — run the cutover in staging against a
   restored snapshot first. See [§9](#9-production-cutover).
8. **Cut over by draining, not by mixing** — quiet and stop every Sidekiq worker,
   confirm nothing is in flight, then start Wurk. Rolling back is the same drain in
   reverse plus one extra check (Wurk's private lists must be empty). Both procedures
   are in [§9](#9-production-cutover). No schema change is made in either direction.

---

## 9. Production cutover

This is the playbook for moving a **live** Sidekiq fleet (OSS, Pro or Enterprise) to
Wurk without losing a job. It is a **drain cutover**: every Sidekiq worker stops
before the first Wurk worker starts. Enqueuing never stops (web processes keep
pushing, and the jobs wait in Redis), but nothing is *processed* between the last
Sidekiq worker exiting and the first Wurk worker fetching. That gap is normally
seconds to a minute. Periodic ticks that fall inside it are not backfilled, which is
also how Sidekiq Enterprise behaves.

> **Why not a rolling mix?** Running Sidekiq and Wurk workers against one Redis at
> the same time has not been tested, and these known gaps make it unsafe until it is:
> stock Sidekiq never reclaims Wurk's five-segment private lists ([§4](#4-redis-key-layout-identical-no-namespace)), so a job in
> one when its Wurk process dies is stranded; Enterprise leader election
> (`dear-leader`) and unique locks (`unique:<digest>`) have not been exercised across
> the two implementations, so an overlap risks a doubled or missed cron tick and
> duplicate unique jobs; and Wurk's batch "already fired" markers are implemented
> from the spec, not checked against a real Pro batch
> ([divergence](idea/parity-divergences.md#batch-fired-markers-use-b-bid-success-complete)).
> This section will add a mixed-fleet path when an integration test proves one.

Run these in bash. Every Redis command goes through one wrapper, so it always targets
the production Redis; define it once per shell:

```bash
r() { redis-cli -u "$REDIS_URL" "$@"; }
```

The `bin/rails runner` commands work under either gem, because Wurk answers to the
same `Sidekiq::*` API.

### 9.1 Pre-flight checklist

Do this days ahead, not on the night.

**Redis**

- [ ] Version ≥ 7.0: `r INFO server | grep redis_version`.
- [ ] Topology Wurk supports: standalone or Sentinel. Redis Cluster is not supported
      (`nodes:` raises). Hosted and Redis-compatible backends: see
      [deployment](deployment.md).
- [ ] No `redis-namespace`: Wurk has no namespacing (`namespace:` raises). A
      namespaced Sidekiq dataset needs its own Redis DB or instance first.
- [ ] `r CONFIG GET maxmemory-policy` answers `noeviction`. An evicting policy
      can silently drop queue lists and private lists.

**Gems**

- [ ] `Gemfile`: `sidekiq`, `sidekiq-pro`, `sidekiq-ent` (and their private gem
      sources) replaced by `wurk`.
- [ ] Each `sidekiq-*` add-on either replaced by its native equivalent
      ([§6](#6-third-party-gem-mappings)) or kept with the `sidekiq` shim gem. Only
      sidekiq-cron's own suite runs against Wurk in CI; every other add-on is
      untested, so exercise it in the staging dry run.
- [ ] `bundle info sidekiq` points into the wurk checkout (`ecosystem/sidekiq-shim`)
      or reports no such gem, never a released `sidekiq-x.y.z`.

**Configuration** (existing initializers keep working; check these explicitly)

- [ ] `config.reliable_scheduler!` is **on**. The default scheduler pops due jobs and
      then pushes them, so a process death between the two loses the job
      ([reliability](reliability.md#the-reliable-scheduler)). `config.super_fetch!`
      can stay; it is a no-op because reliable fetch is always on.
- [ ] `Sidekiq::Enterprise.unique!` and `Sidekiq::Enterprise::Crypto.enable(...)` kept,
      with the **same** encryption keys. A job Wurk cannot decrypt goes straight to
      the dead set, without retries.
- [ ] `config.periodic` blocks kept as they are; sidekiq-cron entries moved
      ([§6](#moving-a-live-sidekiq-cron-schedule)).
- [ ] Process command lines: `sidekiq` → `wurk` or `wurkswarm` (there is no `sidekiq`
      binary; `sidekiqswarm` is an alias). `config/sidekiq.yml` is still discovered.
      `SIDEKIQ_MAXMEM_MB`, `SIDEKIQ_LEADER` and `SIDEKIQ_COUNT` are honoured.
- [ ] `WURK_COUNT × concurrency` sized against your DB connection limit and memory
      ([§2](#2-concurrency-vs-parallelism-read-this)). How the default process count
      is derived inside a container, and supported deployment shapes: see
      [deployment](deployment.md).
- [ ] Web role runs with `WURK_DISABLED=1` so clustered Puma does not fork swarms
      ([§3](#clustered-puma--the-embedded-swarm-important)), and the dashboard mount
      is behind your app's auth ([authentication](authentication.md)).

**Error reporting**

- [ ] Every reporter you rely on is wired through `config.error_handlers` (Honeybadger,
      Rollbar, Bugsnag, Airbrake, Datadog, a custom notifier). Wurk calls each one once
      per job failure with `context: "Job raised exception"`, as Sidekiq does.
- [ ] `sentry-sidekiq` replaced by `Wurk::Sentry` ([sentry](sentry.md)).

**Code that behaves differently** (the full list is
[below](#behaviour-differences-to-know-before-cutover))

- [ ] `grep -rn 'perform_in("' app lib`, plus `set(wait: "…")` and the like: a String
      interval raises `ArgumentError` in Wurk instead of silently meaning "now".
- [ ] Nothing branches on `Sidekiq.pro?` / `Sidekiq.ent?` (both `false`) or reads
      `Sidekiq::Enterprise::VERSION` (undefined).
- [ ] No custom fetcher subclassing `Sidekiq::BasicFetch`, and no Sidekiq Web
      extension that depends on the ERB helpers (`Sidekiq::WebHelpers`).

**Operations**

- [ ] Probes, metrics and alerts in place before the switch: health checks and
      metrics endpoints per [deployment](deployment.md) and [metrics](metrics.md); an
      alert on dead-set growth and on `queue:*|*` key count. Keep
      [the runbook](runbook.md) open on the night.

**Staging dry run against a copy of production Redis.** This is the step that
matters most, because it is the only check of Pro/Enterprise data formats against
*your* data ([§4](#4-redis-key-layout-identical-no-namespace)).

1. Restore a recent production snapshot into a staging Redis
   (`redis-cli -u "$PROD_REDIS_URL" --rdb dump.rdb`, then load it into the staging
   instance).
2. Point a staging Wurk release at it, with **staging** databases and credentials and
   outbound side effects (mail, payments, webhooks) disabled: the restored jobs will
   execute.
3. Check, in order: queues drain; scheduled and retry jobs promote; at least one batch
   that was in flight in the snapshot completes and fires its callbacks; limiters
   admit and throttle; every periodic loop shows in the **Cron** tab with the right
   next fire; a unique job enqueued twice runs once; an encrypted job decrypts; a
   deliberately failing job reaches your error reporter.
4. Run the drain and rollback below against staging once, end to end, with a stopwatch.

### 9.2 Drain Sidekiq

Ship the release that swaps the gem to web and workers together; the worker side does
the following. While web processes roll, jobs from both clients land in the same
queues and wait for whichever worker fleet is running. Plain job JSON is
interchangeable in both directions (the parity suite runs stock Sidekiq's dispatch
on Wurk payloads and a Wurk swarm on Sidekiq-shaped ones); Enterprise client features
crossing the boundary are covered only by your staging dry run.

1. **Quiet every Sidekiq process.** Each one stops fetching and finishes what it has.

   ```bash
   kill -TSTP <sidekiq pid>        # per process, or the sidekiqswarm parent
   # or, cluster-wide from a console on the OLD release:
   bin/rails runner 'Sidekiq::ProcessSet.new.each(&:quiet!)'
   ```

   Sidekiq Web's **Busy → Quiet All** does the same. A quieted Enterprise leader keeps
   enqueueing periodic jobs; that is fine, they wait in the queue for Wurk.

2. **Wait until nothing is busy.**

   ```bash
   r SMEMBERS processes | while read -r p; do
     printf '%s quiet=%s busy=%s\n' "$p" "$(r HGET "$p" quiet)" "$(r HGET "$p" busy)"
   done
   bin/rails runner 'puts Sidekiq::Workers.new.size'    # 0 when drained
   ```

   Every process should read `quiet=true busy=0`. A job that outlives your patience is
   not lost: at stop, Sidekiq pushes unfinished work back to its queue (and Pro's
   super_fetch drains its private list), and it runs again on Wurk. That is the normal
   at-least-once contract.

3. **Stop Sidekiq.** `kill -TERM` each process (or scale the worker deployment to zero)
   and wait for exit. `r SCARD processes` drops to `0`; a process that was
   SIGKILLed lingers there for up to 60s until its heartbeat expires.

4. **Confirm no private lists are left.**

   A name matching `queue:*|*` is a private list only if it is not itself a public
   queue: a queue may legally be called `has|pipe`, which makes `queue:has|pipe` a
   public queue whose name `has|pipe` is a member of the `queues` SET. The helpers below skip those, and recover each private
   list's public queue as the longest `queues` member it starts with (a `|` inside a
   queue name makes a plain split on `|` wrong).

   ```bash
   private_lists() {   # queue:*|* keys that are not public queues
     r --scan --pattern 'queue:*|*' | while read -r k; do
       [ "$(r SISMEMBER queues "${k#queue:}")" = 1 ] || echo "$k"
     done
   }
   public_queue_of() { # longest queue:<name> prefix of $1 whose name is in the queues SET
     local best="" q
     while read -r q; do
       case "$1" in "queue:$q|"*) [ ${#q} -gt ${#best} ] && best="$q" ;; esac
     done < <(r SMEMBERS queues)
     [ -n "$best" ] && echo "queue:$best"
   }

   private_lists | while read -r k; do echo "$k $(r LLEN "$k")"; done
   ```

   Expect no output: OSS Sidekiq never creates these, and Pro's super_fetch empties
   them on a clean stop. If any remain (a SIGKILLed Pro process), move them back
   before starting Wurk. Wurk reclaims Pro's exact `queue:<q>|<host>|<pid>|<index>`
   shape once the owner's heartbeat has expired, but skips any other shape. With **no
   worker of either kind running**:

   ```bash
   private_lists | while read -r k; do
     q="$(public_queue_of "$k")" || { echo "skip $k: no matching queue in the queues SET, move it by hand"; continue; }
     while [ -n "$(r LMOVE "$k" "$q" RIGHT RIGHT)" ]; do :; done
   done
   ```

   `RIGHT RIGHT` puts each job back at the fetch end of its queue, so recovered work
   runs first, which is what Wurk's own reaper does.

### 9.3 Start Wurk

Start the workers (`bundle exec wurkswarm -e production`, or roll out the worker
deployment). Within a few seconds `r SMEMBERS processes` lists the new
identities and the dashboard's **Busy** page shows them.

### 9.4 Verify

Work through this in the first fifteen minutes:

| Check | How | Healthy |
|---|---|---|
| Processes and capacity | Dashboard **Busy**, or `bin/rails runner 'p Sidekiq::ProcessSet.new.total_concurrency'` | `WURK_COUNT × concurrency` per host |
| Queues draining | Dashboard **Queues**, or `bin/rails runner 'Sidekiq::Queue.all.each { \|q\| puts "#{q.name} #{q.size} #{q.latency.round(1)}s" }'` | Sizes and latency falling toward your normal |
| A canary per queue | `bin/rails runner 'Sidekiq::Queue.all.each { \|q\| CanaryJob.set(queue: q.name).perform_async(q.name) }'` with a trivial job that logs its argument | One log line per queue, `Sidekiq::Stats.new.processed` rising |
| Scheduled and retry | Dashboard **Scheduled** / **Retries** | Counts stable or falling; due entries promote |
| Dead set | Dashboard **Dead**, `bin/rails runner 'p Sidekiq::DeadSet.new.size'` | No jump. A jump is the [poison-job storm](runbook.md#poison-job-storm) runbook |
| Periodic leader | `r GET dear-leader`, or `bin/rails runner 'p Sidekiq::ProcessSet.new.leader'` | A Wurk identity within about 60s of boot; the next tick appears as **last fire** on the **Cron** tab |
| Batches | Dashboard **Batches**; `bin/rails runner 'p Sidekiq::Batch::Status.new("<bid>").data'` for one that was in flight | In-flight batches complete and fire their callbacks |
| Error reporting | Enqueue a job that raises | It reaches every reporter in `config.error_handlers` |
| Private lists | `private_lists \| wc -l` (§9.2 step 4) | About processes × queues, not growing |
| Metrics and probes | Per [deployment](deployment.md) and [metrics](metrics.md) | Green |

### 9.5 Rollback

Rolling back is the same drain in reverse, plus one check that is not optional.

1. **Have the old release ready** (the `Gemfile` revert, built and deployable).
2. **Quiet Wurk.** `kill -TSTP <wurkswarm parent pid>` (the parent relays it to every
   child), or the dashboard's **Busy → Quiet**. Wait for `busy=0` with the same loop
   as §9.2 step 2.
3. **Stop Wurk.** `kill -TERM`. Anything still running at the shutdown timeout is
   moved back to the front of its queue before the process exits.
4. **Make sure Wurk's private lists are empty.** Run the §9.2 step 4 scan. Stock
   Sidekiq never reclaims private lists, and Sidekiq Pro's handling of Wurk's
   five-segment names (`queue:<q>|<host>|<pid>|<nonce>|<index>`) has not been
   verified, so a job left in one would sit there forever. After a clean stop the scan
   prints nothing; if it prints anything (a SIGKILLed Wurk process), move it back with
   the same `LMOVE` loop, with no worker running.
5. **Start Sidekiq.**
6. **Know what does not carry back.** Wurk-only features (`collapse:` debounce and
   throttle, flows, `config.global_concurrency`, `track:`, `timeout:` / `deadline:`)
   are not honoured by Sidekiq; their extra job-JSON keys are inert to it. Periodic
   loops Wurk registered sit in Enterprise's own `periodic` schema; a sidekiq-cron
   schedule is still where it was, because the import never deletes it. Unique locks
   Wurk took expire on their `unique_for` TTL. Wurk-only Redis keys are ignored by
   Sidekiq ([compatibility](compatibility.md)).

### Behaviour differences to know before cutover

The deliberate differences from Sidekiq Pro/Enterprise that you can observe in
production. Each one links to its full rationale in
[`parity-divergences.md`](idea/parity-divergences.md).

| Difference | What you see | What to do |
|---|---|---|
| Reliable fetch is always on, and recovered or requeued jobs go to the **front** of their queue (Pro: the back) | A job interrupted by a crash or deploy runs before the backlog | Nothing |
| The ACK rides the next fetch | A hard kill (`SIGKILL`, OOM) can re-run a job that had just finished | Keep jobs idempotent, as at-least-once already requires |
| Paused queues are read from a 2s cache | A pause takes up to 2s to stop fetching | Nothing |
| Limiter reschedule cap goes to the dead set, tagged `rate_limited`, instead of the retry cycle; limiter `ttl` below 24h is raised to 24h | Over-limit jobs land in **Dead** after `reschedule` attempts | Alert on dead-set growth; retry from the dashboard |
| An undecryptable job goes straight to the dead set | Missing or wrong key → **Dead**, no retries | Configure the same keys before starting; retry once fixed |
| Periodic slots more than max(90s, 1.5× tick) late are skipped and logged; a Hash `args:` is passed as one argument (Ent splats it) | A long leader outage skips rather than fires late | Check loops registered with Hash `args` |
| Batch "already fired" markers and child-batch callback accounting follow the spec, unverified against a real Pro batch | A batch in flight at the swap could miss a callback | Let critical batches finish before the cutover, or prove it in the dry run |
| A poison kill (3 crash-reclaims in 72h) fires death handlers, and the counter resets on ACK | The job lands in **Dead**; its batch sees a death | Nothing; see the [runbook](runbook.md#poison-job-storm) |
| `:leader` can fire again after a Redis error | A leader hook runs twice | Make `on(:leader)` hooks idempotent |
| String intervals to `perform_in` / `set(wait:)` raise | `ArgumentError` at enqueue | Pass numbers or durations |
| `SortedEntry#reschedule` returns nil for a job that is already gone | No resurrection of a promoted or deleted job | Nothing |
| A scheduled job's `expires_in` counts from its scheduled time | Follows the spec's worked example | Nothing |
| `Sidekiq.pro?` / `.ent?` are false; `Sidekiq::Enterprise::VERSION` and the ERB Web internals don't exist | Code gated on them takes the OSS branch | Remove the gates |

---

*Found a blocker not covered here? File an issue at
<https://github.com/developerz-ai/wurk/issues>.*
