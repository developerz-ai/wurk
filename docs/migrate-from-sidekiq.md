# Migrating from Sidekiq to Wurk

Wurk is an independently implemented, **wire-compatible** drop-in for Sidekiq + Sidekiq Pro + Sidekiq
Enterprise: the same Redis key schema, the same job JSON, and the same Ruby DSL. In
the common case the migration is a one-line `Gemfile` change — your existing jobs,
batches, limiters, cron entries, and live Redis data keep working untouched, and the
Pro/Enterprise features ship in the same free gem with no license check.

This guide covers what stays the same, the two knobs that surprise people
(parallelism vs concurrency), how to run a dedicated worker, the third-party gem
mappings, a one-page checklist, the [production cutover](#9-production-cutover)
playbook for moving a live Sidekiq Pro/Enterprise fleet, and
[§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems) for 7.x apps that keep
their add-on gems.

**How to read the claims here.** "Verified" names what was run. "Unverified" means nobody
has checked it against that software, most often because Sidekiq Pro and Enterprise are
closed: their formats are known here only through [`docs/target/`](target/sidekiq-pro.md),
which was compiled from public documentation, and no real Pro/Enterprise dump has been
compared. Treat unverified items as open until your staging dry run closes them.

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
> Sidekiq **8.1.x**, including its millisecond job timestamps. Coming from 7.x, read
> [the timestamp warning](#millisecond-timestamps-on-a-7x-app). Requires **Ruby ≥ 3.2** and **Redis ≥ 7.0**. Without `fork` (JRuby,
> TruffleRuby, Windows; untested in CI) only `wurk` and `config.wurk.embed_in_web` apply.

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
mount Wurk::Engine => "/wurk"
```

An existing `mount Sidekiq::Web => "/sidekiq"` keeps working in a Rails app and shows the
same dashboard behind the same gates, so this line is optional.

Optionally scaffold an initializer:

```bash
bin/rails g wurk:install          # writes config/initializers/wurk.rb
```

**The Redis keys and sorted-set scores are the same, so there is no data migration**: Wurk
picks up the queues, schedules, retries and periodic loops Sidekiq left in Redis, and every
job shape tested runs after going back. Going back is not a clean mirror image from 7.x:
Wurk writes millisecond timestamps, which Sidekiq 7.x misreads
([details](#millisecond-timestamps-on-a-7x-app)).

Running Sidekiq and Wurk workers against one Redis at the same time is not the supported
path. A manual soak with stock Sidekiq 7.3.10 and a Wurk swarm on one queue (6,000 jobs,
retries, `SIGKILL`s) lost nothing, and heartbeats, `quiet!` and `stop!` worked across the two.
That run is not in CI and does not cover Pro or Enterprise: how Pro's orphan sweep treats
Wurk's private lists, and how Enterprise's leader election and unique locks behave next to
Wurk's, are unverified. So the supported production path is a **drain cutover**: stop
Sidekiq's workers, then start Wurk's. The procedure, with the exact commands, is
[§9](#9-production-cutover).

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

The gem ships two standalone runners (and an alias). `wurk` has no `sidekiq` executable,
so update any `bundle exec sidekiq` invocation, Procfile line, and systemd/Capistrano unit.
(With the [`sidekiq` shim gem](../ecosystem/sidekiq-shim/README.md) in the bundle,
`bundle exec sidekiq` does run Wurk, so a start script can move later.)

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

When you mount the engine, the railtie forks a swarm **only inside a running web
server** (or with `WURK_EMBED=1`). `WURK_DISABLED=1`, `rails runner`, rake tasks, the
console and the test env all skip it. Under a **preforking server** (Puma with
`workers > 0`, Unicorn, Passenger) the railtie **refuses to fork and logs a warning**,
so that process runs no jobs until you start workers yourself.

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
| `b-<bid>*`, `batches` | HASH/SET/ZSET | ⚠️ Pro batch schema, but the marker semantics differ: Wurk's `b-<bid>-success`/`b-<bid>-complete` mean "already fired" (callbacks enqueued), Pro §2.8 describes the same keys as "callbacks pending" — a batch in flight at the swap may miss callbacks; see [§9](#behaviour-differences-to-know-before-cutover) |
| `loops:<lid>`, `periodic` | HASH/SET | ✅ Enterprise periodic schema |

Job JSON fields are the Sidekiq set: `class, args, queue, jid, created_at,
enqueued_at, retry, retry_count, failed_at, retried_at, error_class, error_message,
error_backtrace` (base64+zlib), plus the optional Pro/Ent fields (`bid, tags,
expiry, …`). The dead set is trimmed by `dead_max_jobs` (default 10,000) and
`dead_timeout_in_seconds` (default 180 days), same as Sidekiq.

**Implication:** Wurk reads what Sidekiq wrote, and `redis-cli` introspection keeps working.
Sidekiq's own web UI on data Wurk wrote is a mixed picture from 7.x: on 7.3.10 every page
tested answered 200, but detail pages show dates in the year 58807 and queue latency is a
large negative number ([why](#millisecond-timestamps-on-a-7x-app)).

Two families differ:

- **Private lists.** Wurk names its reliable-fetch lists
  `queue:<q>|<host>|<pid>|<nonce>|<index>` (five segments; the nonce separates PID-namespace
  reuse). [Pro §3.2](target/sidekiq-pro.md#32-algorithm) gives `queue:<q>|<host>|<pid>|<index>`,
  and Wurk reclaims that four-segment shape. **Whether real Sidekiq Pro writes that shape is
  unverified**; any other shape is left alone, with one warning per process, and its jobs stay
  stranded until moved by hand. Run `wurk preflight` against production to see which shapes you
  have. Stock Sidekiq never reclaims Wurk's lists.
- **Per-class metrics.** Sidekiq 7.3 writes `j|YYYYMMDD|H:M` and `<Class>-DD-H:M`; Wurk writes
  the 8.x `j|YYMMDD|H:MM` and `h|<Class>-D-H:M`. Neither reads the other's on a 7.x app, so
  metrics history starts empty after the swap, and again after a rollback. Jobs are unaffected.

Pro/Enterprise key formats (batches, `lmtr*` limiters, `unique:<digest>` locks,
`dear-leader`, `loops:<lid>`) are implemented against the documented spec in
[`docs/target/`](target/sidekiq-ent.md), not yet validated against a dump taken from a
real Pro/Enterprise deployment. The staging dry run in [§9](#9-production-cutover) is
how you close that gap for your own data before production. A batch in flight at the
swap is not covered by the batch-schema claim above: Wurk's `b-<bid>-success` and
`b-<bid>-complete` markers mean "already fired" (callbacks enqueued, not necessarily
executed), while Pro §2.8 describes the same keys as "callbacks pending", so its
callbacks may not fire — the markers are per-event, so a Pro-shaped `b-<bid>-success`
marker suppresses only `:success` while `:complete` still fires; let critical batches
finish before the cutover, or prove it in
the dry run (see [§9](#behaviour-differences-to-know-before-cutover)).

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
| `lock:` | ⚠️ only with the gem | **Silently ignored without `sidekiq-unique-jobs`:** every push enqueues, so duplicates run. `wurk` and `wurkswarm` log a WARN at boot naming the loaded classes, and `wurk preflight --app` lists them. Keep the gem ([§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems)) or move each class ([§6](#sidekiq-unique-jobs--native-unique_for--unique_until)) |

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

Wurk ships native replacements for the most common add-on gems, and dropping the gem is
the path with the fewest moving parts. Replacing an add-on is an application change, though,
so a large app may want to cut over first and replace later:
[§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems) is that path, and says what
was verified for each gem.

Keeping an add-on gem needs the `sidekiq` shim gem (see the warning under
[TL;DR](#tldr--flip-the-switch)). Four gems, **`sidekiq-cron`**, **`sidekiq-unique-jobs`**,
**`sidekiq-failures`** and **`sentry-sidekiq`**, have their upstream suite and a real worker
boot run against Wurk in the [`ecosystem` CI job](../.github/workflows/ecosystem.yml) (harness
and exclusions in [`test/ecosystem/`](../test/ecosystem/README.md)). The state of the rest is in
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
Redis keys and is visible in the dashboard. `mgr.load_file` and `mgr.load_hash` take
sidekiq-cron's YAML shape directly.

**One difference to plan for: late ticks.** A native slot more than max(90s, 1.5× tick) late is
skipped and logged, not fired. sidekiq-cron's `reschedule_grace_period` can fire a missed tick
later than that. A cutover gap past 90s can therefore skip a tick the gem would have caught, so
list what is due inside your window (a daily billing run, say) and fire it by hand if it passes.

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
   sidekiq-cron's poller next to Wurk's for the same entries: they do not read each other's
   keys, so both fire. If you keep sidekiq-cron for now
   ([§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems)), don't import the
   entries it still owns.
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
| `lock: :until_executing` | `unique_until: :start` (lock released as the job starts) |
| `lock: :while_executing` | **No equivalent.** This lock lets every push through and stops two copies running at once. `unique_until: :start` does neither: it drops duplicate pushes and allows concurrent runs. Use a [concurrent limiter](rate-limiting.md) inside `perform`, or keep the gem |
| `lock: :until_and_while_executing` | **No equivalent.** `unique_until: :start` covers only the enqueue half. Add a concurrent limiter for the execution half, or keep the gem |
| `lock_ttl` | `unique_for: <seconds>`, required here (also accepts an `ActiveSupport::Duration`). The lock ends at that TTL whether or not the job has run |
| `lock_timeout` | No equivalent: a duplicate is dropped at once, never waited on |
| `on_conflict: :reject`, `:log` | The default: `perform_async` returns `nil` and logs. The gem's `:reject` also sends the duplicate to the dead set, which Wurk does not do |
| `on_conflict: :reschedule`, `:raise`, `:replace` | **No equivalent.** A duplicate is dropped, so a job relying on `:reschedule` to run again later loses that run. Keep the gem, or schedule the follow-up in your own code |
| `lock_args_method` / custom uniqueness args | define `self.sidekiq_unique_context(job)` on the worker, returning any JSON-serializable value |

> ⚠️ Unique jobs and encryption are **mutually exclusive on the same worker** — each
> encryption produces different ciphertext, which defeats the uniqueness digest.

#### Moving off sidekiq-unique-jobs during a cutover

There is no import for sidekiq-unique-jobs, by design. Its locks live under
`uniquejobs:*` with its own digest algorithm, Wurk's under `unique:<digest>`; they
are disjoint, and Wurk never reads or releases the gem's locks.

What that means if you drop the gem in the cutover:

- Every class must be moved first. A class still saying `lock:` has **no uniqueness at all**
  on Wurk: that is not one extra run but every duplicate, indefinitely. The boot WARN and
  `wurk preflight --app` list them.
- Jobs that were enqueued under a gem lock and are still in a queue, in `schedule` or in
  `retry` run normally. The gem's `lock*` payload fields are inert to Wurk.
- For a class you moved, a new enqueue takes a fresh `unique:` lock and does not see a job
  enqueued under the gem's lock before the cutover. The race is one extra run per identity,
  for as long as such a job is outstanding. If that is unacceptable for a class (payments,
  outbound messages), drain its scheduled and retry entries first, or make the job idempotent
  ([reliability](reliability.md#idempotency-is-yours)).
- **Leftover gem locks are harmless on Wurk and harmful on the way back.** Wurk does not release
  them, so after a rollback to the gem, `perform_async` for that identity returns `nil` and the
  job is silently not enqueued, until the lock's TTL. Verified on stock 7.3.10 with sidekiq-unique-jobs
  8.1.0 and a 2h `lock_ttl`. Before starting Sidekiq on a rollback:
  `redis-cli -u "$REDIS_URL" --scan --pattern 'uniquejobs:*' | xargs -r -n 500 redis-cli -u "$REDIS_URL" UNLINK`.
  The trade: a job already queued can then be enqueued once more.

If you keep the gem instead, its locks carry over in both directions
([§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems)) and there is nothing to unlink.

### `sentry-sidekiq` → native `Wurk::Sentry`

`sentry-sidekiq` declares `add_dependency "sidekiq"`, so without the shim gem
`bundle install` pulls real Sidekiq back in and `require "sidekiq"` loads a hybrid
of the two. With the shim it loads and reports job failures
([§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems)), but it sees none of the
worker-process errors. The built-in integration needs no extra gem
([why](sentry.md#why-not-sentry-sidekiq)):

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
"Untested" means exactly that, so treat it as unknown and verify it in staging. The gems in
§10 have a fuller account of what was run.

| Gem | Status on Wurk | Notes |
|---|---|---|
| `sidekiq-cron` | ✅ upstream suite and a real worker boot in CI | [§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems), or native `config.periodic` |
| `sidekiq-unique-jobs` | ✅ upstream suite (less one Toxiproxy spec file) and a real worker boot in CI | [§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems), or native `unique_for:` |
| `sidekiq-failures` | ✅ upstream suite (less the ERB home-page test) and a real worker boot in CI | [§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems) |
| `sentry-sidekiq` | ✅ upstream suite and a real worker boot in CI; native preferred | [§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems), or [`Wurk::Sentry`](sentry.md) |
| `opentelemetry-instrumentation-sidekiq` | ⚠️ smoke-tested by hand | [§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems), or native [telemetry](telemetry.md) |
| `rspec-sidekiq` | ⚠️ smoke-tested by hand | [§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems) |
| `sidekiq-status` | ❓ untested | `Sidekiq::WebHelpers::SAFE_QPARAMS`, which its web extension mutates, now exists, but the gem's web specs have not been measured (see `docs/idea/14-ecosystem-compat.md`). Wurk's native `track:` (`Wurk::Status`, `status:<jid>`) is the supported path; the two use different keys and never read each other |
| `sidekiq-scheduler` | ❓ untested | prefer native `config.periodic` |
| `sidekiq-throttled` | ❓ untested | it patches Sidekiq's fetch classes to requeue throttled jobs, and Wurk's reliable fetcher is not one of them; prefer native [rate limiting](rate-limiting.md) |

---

## 7. Known incompatibilities — what *not* to expect

Wurk aims for 100% drop-in, but accepted no-ops and aliases do not imply full
support for every upstream API. In particular, aliasing Sidekiq's Web classes to
Wurk's dashboard does not add class-level Redis pool accessors or a pool-bound
multi-shard mount factory (see item 2). The complete, maintained list of every
place Wurk deliberately behaves differently from the spec is
[`docs/idea/parity-divergences.md`](idea/parity-divergences.md); the ones that matter
on cutover day are summarized in [§9](#behaviour-differences-to-know-before-cutover).
Hit something on a real migration that isn't listed? **Please open an issue** — real
migrations are what this guide is checked against.

1. **`config.super_fetch!` does nothing** (accepted no-op). Wurk's fetcher is
   *always* reliable (atomic `BLMOVE` to a per-process private list, with orphan
   reclamation), so a Sidekiq Pro initializer drops in unchanged — the call just
   no-ops rather than toggling anything.

   **`config.reliable_scheduler!` is a real switch, and optional.** The default poller
   already loses no job: it leases due members, pushes, then removes them, so a crash costs a
   duplicate and up to 60s, not a job. `reliable_scheduler!` swaps in an atomic Lua promoter,
   with about 25x the throughput on a large backlog, which **skips client middleware**. If a client
   middleware must see promoted jobs, leave it off. See
   [`docs/reliability.md`](reliability.md#the-reliable-scheduler).
   (`Wurk::Client.reliable_push!` also exists for client-side buffering during a
   Redis outage.)
2. **Web aliases do not support pool assignment or per-mount shards.** Both
   `Sidekiq::Web` and `Sidekiq::Pro::Web` alias `Wurk::Web`. The class-level
   `Sidekiq::Web.redis_pool` reader and `Sidekiq::Web.redis_pool=` setter are
   **unsupported in Wurk**; both raise `NoMethodError`. The dashboard configuration
   reader is `config.web_redis_pool` on `Wurk::Configuration` (for example,
   `Wurk.configuration.web_redis_pool`), not `Web::Config`. It is read-only: there
   is no `web_redis_pool=` setter for assigning an arbitrary pool. To change the
   dashboard pool's size instead, set `config.web_pool_size = n`; see
   [Redis connection and pool sizing](configuration.md#redis-connection-and-pool-sizing).

   Pool-bound multi-shard mounts using `.with(redis_pool:)` remain **unsupported
   in Wurk**; the alias does not provide that factory. Neither reading
   `config.web_redis_pool` nor setting `config.web_pool_size` selects a per-mount
   shard. See [Pro §10.2](target/sidekiq-pro.md#102-multi-shard).
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
   connections pre-fork and children reconnect). Without `fork`, only `wurk` and
   `config.wurk.embed_in_web` apply; `wurkswarm` has no fallback.
8. **`Sidekiq.pro?` and `Sidekiq.ent?` return `false`** — Wurk is free and reports
   itself as OSS, even though the Pro/Ent features are present. Don't gate behavior on
   these predicates.
9. **`sentry-sidekiq` needs the shim gem** — its gemspec declares
   `add_dependency "sidekiq"`, so without the shim Bundler installs real Sidekiq alongside
   Wurk and `require "sidekiq"` loads a broken hybrid. Wurk ships its own integration:
   `require "wurk/sentry"` + `Wurk::Sentry.install!(config)`. See
   [`docs/sentry.md`](sentry.md).
10. **Upstream Web and metrics internals are intentionally unshimmed.** These
    paths are not Wurk require paths:
    - `sidekiq/web/application.rb` — unsupported upstream internal.
    - `sidekiq/web/router.rb` — unsupported upstream internal.
    - `sidekiq/web/action.rb` — unsupported upstream internal.
    - `sidekiq/web/helpers.rb` — unsupported upstream internal. The constant
      `Sidekiq::WebHelpers` does exist, as a working subset for extension views.
    - `sidekiq/metrics/tracking.rb` — unsupported upstream internal.

    Wurk's SPA dashboard has no drop-in replacement for Sidekiq's Web internals;
    extensions that patch those internals must be adapted, not just re-required.
    Wurk also has no `Sidekiq::Metrics::ExecutionTracker` replacement. For public
    dashboard usage, `require 'sidekiq/web'` is supported; for public metrics
    queries, `require 'sidekiq/metrics/query'` is supported. Neither entrypoint
    provides an equivalent implementation of the unsupported internals.

---

## 8. Cutover checklist

1. **Run `wurk preflight`** against production, days ahead. See
   [§9.1](#91-pre-flight-checklist).
2. **Swap the gem** — replace `sidekiq` (+ `sidekiq-pro` / `sidekiq-ent`) with `wurk`
   in the `Gemfile`; `bundle install`.
3. **Size parallelism × concurrency** — decide `WURK_COUNT` (processes) and
   `concurrency` (threads), then check your DB pool and memory against
   `WURK_COUNT × concurrency`. See [§2](#2-concurrency-vs-parallelism-read-this). This
   is the only step that needs real thought.
4. **Keep your config as-is** — `config.super_fetch!` is an accepted no-op and
   `config.reliable_scheduler!` still works, so there's nothing to strip out. Drop a
   `connection_pool` pin below 3.0 ([§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems)).
5. **Re-point the dashboard route** — `mount Wurk::Engine => "/wurk"` (gate it behind
   your app auth — see [`docs/authentication.md`](authentication.md)).
6. **Split web from workers** — run a dedicated `bundle exec wurkswarm` process and set
   `WURK_DISABLED=1` on the web role: single-mode Puma would otherwise fork a swarm too, and
   clustered Puma refuses to and logs a warning.
   See [§3](#3-running-a-worker-process). Deploying under systemd/Capistrano? See
   [`docs/deployment.md`](deployment.md).
7. **Decide each add-on gem** — keep it through the shim
   ([§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems)) or replace it
   ([§6](#6-third-party-gem-mappings)). A class left with `lock:` and no gem runs duplicates.
8. **Rehearse on a copy of production Redis** — run the cutover in staging against a
   restored snapshot first. See [§9](#9-production-cutover).
9. **Cut over by draining, not by mixing** — quiet and stop every Sidekiq worker,
   confirm nothing is in flight, then start Wurk, then run `wurk verify`. Rolling back is the
   same drain in reverse plus the checks in [§9.5](#95-rollback). No key schema changes in
   either direction; timestamps do ([§10](#millisecond-timestamps-on-a-7x-app)).

---

## 9. Production cutover

This is the playbook for moving a **live** Sidekiq fleet (OSS, Pro or Enterprise) to
Wurk without losing a job. It is a **drain cutover**: every Sidekiq worker stops
before the first Wurk worker starts. Enqueuing never stops (web processes keep
pushing, and the jobs wait in Redis), but nothing is *processed* between the last
Sidekiq worker exiting and the first Wurk worker fetching. That gap is normally
seconds to a minute. Native periodic ticks that fall inside it are not backfilled, which
the Enterprise spec also says ([§2.6](target/sidekiq-ent.md#26-semantics--edge-cases)).
sidekiq-cron with a grace period behaves differently: see
[late ticks](#sidekiq-cron--native-periodic-jobs).

> **Why not a rolling mix?** A manual soak with stock Sidekiq 7.3.10 and a Wurk swarm worked
> ([summary](#tldr--flip-the-switch)), but it is one run, outside CI, without Pro or Enterprise.
> The known risks: stock Sidekiq never reclaims Wurk's five-segment private lists
> ([§4](#4-redis-key-layout-identical-no-namespace)), so a job in one when its Wurk process
> dies waits for a Wurk process (the soak confirmed it, with recovery about 70s after a fresh
> Wurk booted); Pro's handling of those lists, Enterprise leader election (`dear-leader`) and
> unique locks (`unique:<digest>`) have not been exercised across the two implementations, so an
> overlap risks a doubled or missed cron tick and duplicate unique jobs; and Wurk's batch
> "already fired" markers are implemented from the spec, not checked against a real Pro batch.
> Pro §2.8 types `b-<bid>-success`/`b-<bid>-complete` as string/marker too, but there they mean
> "callbacks pending", so a batch in flight at the swap can lose a callback silently
> ([divergence](idea/parity-divergences.md#batch-fired-markers-use-b-bid-success-complete)).
> A queue subset is a lower-risk probe: `wurk -q <queue>` beside stock Sidekiq on the others
> consumed only that queue in the same manual test.

Run these in bash. Every Redis command goes through one wrapper, so it always targets
the production Redis; define it once per shell:

```bash
r() { redis-cli -u "$REDIS_URL" "$@"; }
```

The `bin/rails runner` commands work under either gem, because Wurk answers to the
same `Sidekiq::*` API.

### 9.1 Pre-flight checklist

Do this days ahead, not on the night.

**Start with `wurk preflight`.** It reads a live Redis and reports what will and will not carry
over. It is read-only: only `SCAN` and bounded sampling, through a client that refuses any other
command, pausing between pages. At 1M keys it took about 10s and left Redis latency under 5ms in a
local test. No `LLEN`, no writes. To run it before the gem swap, install `wurk` anywhere that can
reach Redis:

```bash
gem install wurk
wurk preflight --redis-url "$REDIS_URL"              # text; --json for machines
```

| Reports | Means |
|---|---|
| Redis version, eviction policy, topology, Dragonfly | The Redis list below, checked |
| Live processes by version | A stale member, or a fleet you forgot |
| Every `queue:*\|*` key as `owner_alive`, `reclaimable` or `unparseable` | **`unparseable` lists will never be reclaimed.** This is the check of real Pro list names against your data |
| Timestamp shapes and `retry_for` jobs, sampled | Seconds or ms per field; what a rollback will misread |
| In-flight `b-*` with no `callbacks` field | Batches that will fire no callback on Wurk |
| `encrypt` payloads without a Wurk envelope | Jobs Wurk will send to the dead set unrun |
| `uniquejobs:*` and `unique:*` counts, SHA1-length digests | Locks to carry, or that Wurk will not see |

It prints the Redis it read (host, port, DB, never credentials): check it is the one you meant. An empty keyspace is a finding, not "clean". Exit status is `0` clean, `1` findings, `2` could not run. It samples (`--sample`, default 100 per
queue or set) and stops at `--limit` keys (default 2M), saying so and returning 1: a truncated
scan is never called clean. A clean exit is about what it samples. It does not prove every payload.

On the release that swaps the gem, `bundle exec wurk preflight --app .` also boots your app in
server mode, so it reads the Redis your workers would use (`-u` overrides), and lists classes
with `lock:` and no gem, and add-ons known not to work. **That part runs your initializers, and
the read-only promise covers only preflight's own commands.** An initializer that enqueues writes
to the app's Redis whatever `-u` says. A banner and an `app_code_ran` finding say so; point it at
staging if an initializer writes.

**In CI, boot the worker the way a deploy would.** Add one step to the release that swaps the
gem:

```yaml
- name: wurk boot-check
  run: bundle exec wurk boot-check -r . -e production
  env:
    SECRET_KEY_BASE_DUMMY: "1"
```

It exits non-zero, naming the constant, when the worker boot would crash-loop, and it forks
nothing and opens no fetch. Add `--redis` for a read-only check of the server too (version,
eviction policy, live peers).

**Redis**

- [ ] Version ≥ 7.0: `r INFO server | grep redis_version`.
- [ ] Topology Wurk supports: standalone or Sentinel. Redis Cluster is not supported
      (`nodes:` raises). Hosted and Redis-compatible backends: see
      [deployment](deployment.md).
- [ ] No `redis-namespace`: Wurk has no namespacing (`namespace:` raises). A
      namespaced Sidekiq dataset needs its own Redis DB or instance first.
- [ ] `r CONFIG GET maxmemory-policy` answers `noeviction`. An evicting policy
      can silently drop queue lists and private lists.
- [ ] On Dragonfly, keep the store well below `--maxmemory` and alert before it: at the limit a
      move between shards can drop a job ([deployment](deployment.md#dragonfly)).

**Gems**

- [ ] `Gemfile`: `sidekiq`, `sidekiq-pro`, `sidekiq-ent` (and their private gem
      sources) replaced by `wurk`.
- [ ] Each `sidekiq-*` add-on either replaced by its native equivalent
      ([§6](#6-third-party-gem-mappings)) or kept with the `sidekiq` shim gem
      ([§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems)). Exercise each in the
      staging dry run.
- [ ] `bundle info sidekiq` points into the wurk checkout (`ecosystem/sidekiq-shim`)
      or reports no such gem, never a released `sidekiq-x.y.z`.
- [ ] No `connection_pool` pin below 3.0. Wurk needs `>= 3.0, < 4`; a pin kept for Sidekiq 7.x
      stops the bundle resolving.

**Configuration** (existing initializers keep working; check these explicitly)

- [ ] `config.super_fetch!` can stay; it is a no-op because reliable fetch is always on.
      `config.reliable_scheduler!` is optional: see [§7](#7-known-incompatibilities--what-not-to-expect).
- [ ] `Sidekiq::Enterprise.unique!` kept. A 7.x Enterprise lock is not seen by Wurk: per
      [Ent §11](target/sidekiq-ent.md#11-version-map-of-notable-api-additions) those digests
      are SHA1 and Wurk's are SHA256, so expect one duplicate per identity until they expire.
- [ ] **Encrypted jobs drained before the cutover.** Same keys do not help:
      [Ent §4.4](target/sidekiq-ent.md#44-on-wire-format) says Wurk's envelope and
      Enterprise's blob do not round-trip. Keep `Sidekiq::Enterprise::Crypto.enable(...)` for
      new jobs, and let every old one finish on Enterprise first (`wurk preflight` counts what it
      samples). Wurk sends a job with `encrypt` set and no Wurk envelope to the dead set unrun.
      Do not retry one holding foreign ciphertext: a retry seals the argument as it stands, and
      `perform` then receives the ciphertext.
- [ ] `config.periodic` blocks kept as they are; sidekiq-cron entries moved
      ([§6](#moving-a-live-sidekiq-cron-schedule)).
- [ ] Process command lines: `sidekiq` → `wurk` or `wurkswarm` (`bundle exec sidekiq` runs Wurk
      only through the shim gem; `sidekiqswarm` is an alias). `config/sidekiq.yml` is still
      discovered. `SIDEKIQ_MAXMEM_MB`, `SIDEKIQ_LEADER` and `SIDEKIQ_COUNT` are honoured.
- [ ] `WURK_COUNT × concurrency` sized against your DB connection limit and memory
      ([§2](#2-concurrency-vs-parallelism-read-this)). How the default process count
      is derived inside a container, and supported deployment shapes: see
      [deployment](deployment.md).
- [ ] Web role runs with `WURK_DISABLED=1` so clustered Puma does not fork swarms
      ([§3](#clustered-puma--the-embedded-swarm-important)), and the dashboard mount
      is behind your app's auth ([authentication](authentication.md)).

**Rails apps: what changes inside a job** ([changelog](../CHANGELOG.md))

Every job runs inside `Rails.application.reloader`, in every boot mode. Set
`config[:reloader] = nil` to opt out. Check these:

- [ ] **The query cache is on inside a job.** A job that polls a row in a loop can read the
      same stale result. Wrap the poll in `ActiveRecord::Base.uncached { ... }`.
- [ ] **A DB pool smaller than concurrency now fails under load.** Threads no longer keep
      connections, so they wait and then raise `ActiveRecord::ConnectionTimeoutError` under
      contention, and boot logs an ERROR. Set `pool:` to at least `concurrency`, plus any other
      threads that use the database.
- [ ] **`Rails.error` subscribers see job failures**, tagged `job.sidekiq`, including
      `Wurk::JobRetry::Skip` and `Handled`. Filter those in any error tracker subscribed there.
- [ ] `ActiveSupport::CurrentAttributes` now resets between jobs, and a raw
      `ActiveRecord::Base.connection` is released after each. Code that leaned on either carrying
      over will change.

**Error reporting**

- [ ] Every reporter you rely on is wired through `config.error_handlers` (Honeybadger,
      Rollbar, Bugsnag, Airbrake, Datadog, a custom notifier). Wurk calls each one once
      per job failure with `context: "Job raised exception"`, as Sidekiq does.
- [ ] `sentry-sidekiq` replaced by `Wurk::Sentry` ([sentry](sentry.md)), or kept through the
      shim ([§10](#10-sidekiq-7x-proenterprise-apps-keeping-the-add-on-gems)).

**Code that behaves differently** (the full list is
[below](#behaviour-differences-to-know-before-cutover))

- [ ] `grep -rn 'perform_in("' app lib`, plus `set(wait: "…")` and the like: a String
      interval raises `ArgumentError` in Wurk instead of silently meaning "now".
- [ ] Nothing branches on `Sidekiq.pro?` / `Sidekiq.ent?` (both `false`) or reads
      `Sidekiq::Enterprise::VERSION` (undefined).
- [ ] Any custom fetcher subclassing `Sidekiq::BasicFetch` reviewed against the
      [behaviour table and custom-fetcher contract below](#behaviour-differences-to-know-before-cutover),
      including shutdown recovery for unfinished jobs; the alias is Reliable, not
      stock BRPOP BasicFetch.
- [ ] No Sidekiq Web extension that needs an ERB helper outside the working subset `Sidekiq::WebHelpers` provides ([`docs/dashboard.md`](dashboard.md#custom-tabs--web-extensions)).
- [ ] Nothing reads `failed_at`, `created_at`, `enqueued_at` or `retried_at` raw and treats them
      as seconds: [they become milliseconds](#millisecond-timestamps-on-a-7x-app).
      `grep -rnE "\[['\"](failed_at|created_at|enqueued_at|retried_at)['\"]\]" app lib`.

**Operations**

- [ ] Probes, metrics and alerts in place before the switch: health checks and
      metrics endpoints per [deployment](deployment.md) and [metrics](metrics.md); an
      alert on dead-set growth and on `queue:*|*` key count. Keep
      [the runbook](runbook.md) open on the night.
- [ ] Probes that grep `ps` for `sidekiq` are replaced. A Wurk worker's process title differs, so
      such a probe restarts a healthy pod. Use `wurk health`, which boots no app and exits 0 when
      this host has a recent heartbeat ([deployment](deployment.md#health-probes)).

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
   next fire; a unique job enqueued twice runs once; a job **Wurk** encrypted decrypts;
   a deliberately failing job reaches your error reporter. Run `wurk preflight` and `wurk verify`
   against this copy, and read what they say about your real private-list and batch shapes.
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
   not lost: at stop, Sidekiq pushes unfinished work back to its queue, and it runs again
   on Wurk. That is the normal
   at-least-once contract.

   Pro's behaviour at stop is not verified by this project, which is why step 4 checks.

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

   OSS Sidekiq never creates these. For Pro, expect none after a clean stop, but that is
   unverified, so read what this prints. Move anything left back before starting Wurk: Wurk
   reclaims the `queue:<q>|<host>|<pid>|<index>` shape from
   [Pro §3.2](target/sidekiq-pro.md#32-algorithm) once the owner's heartbeat has expired, and
   skips any other shape. A shape whose first segment is not a queue name in the `queues` SET
   gets a `skip` line below and needs a human. With **no worker of either kind running**:

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

Start with `wurk verify`, then work through the table in the first fifteen minutes:

```bash
bundle exec wurk verify                       # read-only; exit 0 clean, 1 findings, 2 could not run
bundle exec wurk verify --canary CanaryJob    # WRITES: also pushes CanaryJob to every subscribed queue
```

It checks that every queue holding jobs has a subscriber, no non-Wurk process is live, private
lists are within what the fleet should hold and none is unreadable, a live Wurk process holds the
leader lock, and every unpaused loop has a next fire. Give a just-started fleet a couple of minutes
and run it again: a stopped process's lists take up to about 2.5 minutes to reclaim. It cannot
compute a next fire for sidekiq-cron entries, and a canary push proves only the push: confirm in
your logs that each ran.

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
   five-segment names (`queue:<q>|<host>|<pid>|<nonce>|<index>`) is unverified, so a job left
   in one may sit there forever. After a clean stop the scan prints nothing; if it prints
   anything (a SIGKILLed Wurk process), move it back with the same `LMOVE` loop, with no
   worker running.
5. **If you dropped `sidekiq-unique-jobs`, unlink its locks now.** Otherwise jobs are silently
   not enqueued until the locks' TTL ([details](#moving-off-sidekiq-unique-jobs-during-a-cutover)):
   `redis-cli -u "$REDIS_URL" --scan --pattern 'uniquejobs:*' | xargs -r -n 500 redis-cli -u "$REDIS_URL" UNLINK`.
   If you kept the gem, skip this: locks carried both ways in testing.
6. **Start Sidekiq.**
7. **Know what you will see on 7.x, and what does not carry back.**
   - Timestamps Wurk wrote read wrongly: negative latency, year-58807 dates, and `retry_for` ignored
     on any job Wurk failed first ([details](#millisecond-timestamps-on-a-7x-app)). Alerts on queue
     latency will misfire until those jobs are gone.
   - A job Wurk encrypted reaches `perform` as the raw envelope on stock Sidekiq (seen on 7.3.10;
     on Enterprise, unverified). Drain encrypted jobs on Wurk before rolling back.
   - A batch Wurk created does not finish under stock Sidekiq: jobs run, `pending` stays put and
     no callback fires. Under Pro, unverified. Let batches finish on Wurk first.
   - Wurk-only features (`collapse:` debounce and throttle, flows, `config.global_concurrency`,
     `track:`, `timeout:` / `deadline:`) are not honoured by Sidekiq; their extra job-JSON keys are
     inert to it. Metrics history restarts.
   - Periodic loops Wurk registered sit in Enterprise's own `periodic` schema per the spec; a
     sidekiq-cron schedule is still where it was, because the import never deletes it. Unique locks
     Wurk took expire on their `unique_for` TTL. Wurk-only Redis keys are ignored by Sidekiq.

### Behaviour differences to know before cutover

The deliberate differences from Sidekiq Pro/Enterprise that you can observe in
production. Each one links to its full rationale in
[`parity-divergences.md`](idea/parity-divergences.md).

| Difference | What you see | What to do |
|---|---|---|
| Reliable fetch is always on, and recovered or requeued jobs go to the **front** of their queue (Pro: the back) | A job interrupted by a crash or deploy runs before the backlog | Nothing |
| Custom `Sidekiq::BasicFetch` subclasses inherit `Wurk::Fetcher::Reliable`, not stock BRPOP BasicFetch | Inherited shutdown `bulk_requeue` requires the payload in Reliable's expected private list; a BRPOP fetch or different ownership scheme can silently skip requeue | Implement recovery for your fetcher's ownership model; see the custom-fetcher contract below |
| The ACK rides the next fetch | A hard kill (`SIGKILL`, OOM) can re-run a job that had just finished | Keep jobs idempotent, as at-least-once already requires |
| Paused queues are read from a 2s cache | A pause takes up to 2s to stop fetching | Nothing |
| Limiter reschedule cap goes to the dead set, tagged `rate_limited`, instead of the retry cycle; limiter `ttl` below 24h is raised to 24h | Over-limit jobs land in **Dead** after `reschedule` attempts | Alert on dead-set growth; retry from the dashboard |
| A job Wurk cannot decrypt goes straight to the dead set: a missing or wrong key, or `encrypt` set with a last argument that is no Wurk envelope | **Dead**, no retries, `error_class` `Wurk::Encryption::DecryptionError`. The second case includes jobs pushed by a producer without crypto enabled, which used to run in the clear. These kills skip the `dead_max_jobs` trim and log an ERROR, though a later ordinary death still applies the cap | Enable crypto on producers first. Retry a key failure once the key is back. Retry a plaintext job freely (the retry seals it). Never retry foreign ciphertext |
| Periodic slots more than max(90s, 1.5× tick) late are skipped and logged; a Hash `args:` is passed as one argument (Ent splats it) | A long leader outage skips rather than fires late | Check loops registered with Hash `args` |
| Wurk uses `b-<bid>-success`/`b-<bid>-complete` as Redis strings holding `"1"` meaning "already fired" (callbacks enqueued, not necessarily executed). Pro §2.8 types the same two keys as string/marker too, but there they mean "callbacks pending" where Wurk means "already fired", and Pro keeps its callback state in the `b-<bid>-notify`/`b-<bid>-cbsucc` sets Wurk never writes. The keys match on type and collide on meaning, so nothing errors | A Pro batch in flight at the swap may miss callbacks — the markers are per-event, so a Pro-shaped `b-<bid>-success` marker loses its `:success` callback **silently** (no Redis type error, no log line, no `success_at`) while `:complete` still fires | Let critical batches finish before the cutover, or prove it in the dry run |
| A poison kill (the 4th crash-reclaim in 72h) fires death handlers, and the counter resets on ACK | The job lands in **Dead**; its batch sees a death | Nothing; see the [runbook](runbook.md#poison-job-storm) |
| `:leader` can fire again after a Redis error | A leader hook runs twice | Make `on(:leader)` hooks idempotent |
| String intervals to `perform_in` / `set(wait:)` raise | `ArgumentError` at enqueue | Pass numbers or durations |
| `SortedEntry#reschedule` returns nil for a job that is already gone | No resurrection of a promoted or deleted job | Nothing |
| A scheduled job's `expires_in` counts from its scheduled time | Follows the spec's worked example | Nothing |
| `Sidekiq.pro?` / `.ent?` are false; `Sidekiq::Enterprise::VERSION` and most ERB Web internals don't exist | Code gated on them takes the OSS branch | Remove the gates |

**Custom-fetcher contract.** `Sidekiq::BasicFetch` is an alias for
`Wurk::Fetcher::Reliable`. On shutdown timeout, Manager passes unfinished units of
work to `bulk_requeue(inprogress)` before killing their processor threads. The
inherited implementation flushes pending ACKs, derives Reliable's expected private
list from each unit's `queue`, and attempts to `LREM` its raw `job` payload there.
It only `RPUSH`es the payload to the public queue if `LREM` removed it. This ownership
guard prevents duplicate recovery; it is **not** a generic RPUSH fallback. A custom
BRPOP fetch leaves no private copy, and a fetcher using a different private list
leaves no copy in the expected list: the inherited method can silently skip requeue.
Implement `bulk_requeue` and unit-of-work ACK/requeue semantics for your own ownership
model rather than inheriting Reliable's recovery blindly. Reliable's unit of work
also assumes its own private copy and fetcher.

The plug-in contract is documented in
[Sidekiq OSS §15](target/sidekiq-free.md#15-sidekiqbasicfetch):

- Fetcher: `initialize(capsule)`, `retrieve_work`, `bulk_requeue(inprogress)`, and
  `terminate`. `retrieve_work` returns a unit of work or `nil`; block or back off
  when no work is available rather than busy-spinning.
- Optional: `flush_pending_acks` (called only when supported). `queues_cmd` is an
  implementation detail, **not** a plug-in requirement.
- Unit of work: `queue` is the public Redis key (`queue:<name>`), `job` is the raw
  JSON string, and `queue_name` is the unprefixed name. Provide `acknowledge` and
  `requeue` with ownership-aware semantics consistent with your fetcher and its
  shutdown recovery.

---

## 10. Sidekiq 7.x Pro/Enterprise apps, keeping the add-on gems

For a large app, replacing every `lock:` and cron entry in the same release as the runtime makes
the release hard to roll back. The alternative is to swap the runtime alone: keep the gems through
the shim, cut over, and replace them later, or not at all.

```ruby
# Gemfile
gem "wurk"
gem "sidekiq", github: "developerz-ai/wurk", glob: "ecosystem/sidekiq-shim/*.gemspec"
gem "sidekiq-unique-jobs"
gem "sidekiq-cron"
gem "sidekiq-failures"
# remove sidekiq-pro, sidekiq-ent, and any pin such as gem "connection_pool", "< 3"
```

Wurk needs `connection_pool >= 3.0, < 4`. An app that pinned it below 3 to stay on Sidekiq 7.x must
drop the pin, and needs to know that **a rollback brings the pin back**, so build the rollback
release from the old lockfile rather than reverting by hand.

The shim reports Sidekiq 8.1, so these gems take their 8.x code paths on Wurk and their 7.x paths
after a rollback. Bundle them at versions that support both.

### What was verified

"Smoke" means a by-hand run on Wurk through the shim: real worker processes, real Redis, the
versions shown, and stock Sidekiq 7.3.10 for anything cross-runtime. It shows the main path works.
It is not the gem's own test suite, and it found real bugs when first run, so **repeat what you
rely on in staging**.

| Gem | Evidence | What was seen | Not verified |
|---|---|---|---|
| `sidekiq-cron` 2.3.1 | Upstream suite plus a real worker boot in CI (pinned by [`test/ecosystem/sidekiq-cron/PIN`](../test/ecosystem/sidekiq-cron/PIN)). Smoke | Entries tick in a real worker, and a stock poller beside it gave one tick a minute, no doubles | Its web tab's actions. Its index page renders through Wurk's ERB extension renderer ([`docs/dashboard.md`](dashboard.md#custom-tabs--web-extensions)), checked by hand on 2.4.0 |
| `sidekiq-unique-jobs` 8.1.0 | Smoke, plus its suite and a real worker boot in CI ([what it leaves out](idea/14-ecosystem-compat.md#sidekiq-unique-jobs)) | `until_executed`, `until_executing`, `while_executing`, `until_and_while_executing` with `on_conflict: :reject`. Dedup works. A lock taken by either runtime is released when the other runs the job, so locks carry both ways. Its reaper saw no orphans for in-flight jobs on Wurk | `on_conflict: :reschedule`, `lock_args_method` and its web tab |
| `sidekiq-failures` 1.1.0 | Smoke, plus its suite and a real worker boot in CI | Failures recorded in `failed`, read back from either runtime. `RetrySet`, `DeadSet` and `ScheduledSet` walk normally with it loaded; `retry_failure` and its web tab through its suite | Web tab against a live 7.x fleet |
| `sentry-sidekiq` 6.7.0 | Smoke, against a dummy transport, not a real Sentry. CI runs 6.5.0's suite and a real worker boot | Boots. Each attempt raises one event with `queue`/`jid` tags and job context; with `report_after_job_retries`, one on the last attempt. Transactions are sent | Worker-process errors, which it does not see: [`Wurk::Sentry`](sentry.md) covers those and is what Wurk's own suite tests |
| `opentelemetry-instrumentation-sidekiq` 0.29.0 | Smoke | `publish` and `process` spans. It writes `traceparent` to the payload, inert to either runtime | Anything but those two spans. Native [telemetry](telemetry.md) is the tested path |
| `rspec-sidekiq` 5.3.0 | Smoke: a small spec, not the gem's suite | `have_enqueued_sidekiq_job` (with `.at`, `.in`), `enqueue_sidekiq_job`, `be_processed_in`, `be_retryable`, `save_backtrace`, `.jobs`, `.drain`, `Testing.inline!` | Other matchers. It runs in your test suite, so failures are visible at once |

None of this was run against Sidekiq Pro or Enterprise, because their code is licensed. Everything
cross-runtime above means stock OSS Sidekiq.

### Millisecond timestamps on a 7.x app

Sidekiq 7.x stores `created_at`, `enqueued_at`, `failed_at` and `retried_at` as float seconds.
Wurk stores integer milliseconds, as Sidekiq 8 does. Wurk reads both, so forward is safe for Wurk's
own code. There is no option to change this.

**Your code, on Wurk.** Anything reading these fields raw and treating them as seconds breaks:
`Time.at(job.item['failed_at'])` lands in the year 58807, so a "failed in the last hour" filter
matches everything. Use the readers on the job record (`job.failed_at`, `job.created_at`,
`job.enqueued_at`), which handle both shapes, or divide by 1000 when the value is at least 10¹⁰.
During the cutover both shapes exist at once, sometimes within one payload.

**Sidekiq 7.x, on what Wurk wrote** (observed on 7.3.10, on a rollback):

| What | You see | Consequence |
|---|---|---|
| `Sidekiq::Queue#latency`, `JobRecord#latency` | About `-1.79e12` | Latency alerts stay quiet or misfire until those jobs are gone |
| `JobRecord#created_at`, `#enqueued_at`, web UI detail pages | Dates in the year 58807. Pages still answer 200 | Cosmetic, but alarming on the night |
| `retry_for` on a job Wurk failed first | **Ignored**: the expiry test compares ms with seconds and never passes | The job keeps retrying to its `retry` count, far past `retry_for` |
| Job execution, retry counts, dead-set moves, `retry` and `add_to_queue` from the API | Normal | |

The set of jobs affected shrinks as they run. Nothing about it loses a job.

### A cutover in this shape

1. Days ahead: `wurk preflight --redis-url ...` against production. Read every `unparseable` line.
2. Grep for raw timestamp reads and `ps` probes ([§9.1](#91-pre-flight-checklist)).
3. Build the Wurk release with the gems kept, and the rollback release from the old lockfile.
4. Dry-run both directions on a copy of Redis, with side effects off ([§9.1](#91-pre-flight-checklist)).
5. Optional probe: run Wurk on one low-risk queue beside the old fleet (`wurk -q <queue>`, removing
   that queue from the old fleet). Verified with stock Sidekiq only; unverified next to Pro.
6. [Drain](#92-drain-sidekiq), [start Wurk](#93-start-wurk), then `wurk verify`.
7. Replace the gems later, one at a time ([§6](#6-third-party-gem-mappings)), each in its own release.

---

*Found a blocker not covered here? File an issue at
<https://github.com/developerz-ai/wurk/issues>.*
