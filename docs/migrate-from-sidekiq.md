# Migrating from Sidekiq to Wurk

Wurk is a clean-room, **wire-compatible** drop-in for Sidekiq + Sidekiq Pro + Sidekiq
Enterprise: the same Redis key schema, the same job JSON, and the same Ruby DSL. In
the common case the migration is a one-line `Gemfile` change — your existing jobs,
batches, limiters, cron entries, and live Redis data keep working untouched, and the
Pro/Enterprise features ship in the same free gem with no license check.

This guide covers what stays the same, what to watch for, and a one-page cutover.

- **Authoritative API surface:** [`docs/target/sidekiq-free.md`](target/sidekiq-free.md) ·
  [`sidekiq-pro.md`](target/sidekiq-pro.md) · [`sidekiq-ent.md`](target/sidekiq-ent.md)
- **Why this is legal:** [`docs/clean-room.md`](clean-room.md)

> Verified against Wurk's Sidekiq-compat layer (`lib/wurk/compat.rb`), which mirrors
> Sidekiq **8.1.x**. Requires **Ruby ≥ 3.2** and **Redis ≥ 7.0**.

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
| `concurrency` | threads per worker (default `5`) |
| `queues` | ordered/weighted queue list |
| `redis = { url:, … }` | defaults to `ENV["REDIS_URL"]` → `redis://localhost:6379/0` |
| `logger`, `logger =` | standard `Logger` |
| `timeout` | job + shutdown grace seconds (default `25`) |
| `error_handlers`, `death_handlers` | arrays of callables |
| `client_middleware` / `server_middleware` | same `Chain#add/remove/insert_before` API |
| `on(:startup\|quiet\|shutdown\|exit\|heartbeat\|beat\|leader)` | lifecycle hooks |
| `capsule(name) { … }` | multi-queue capsules (Sidekiq 7+) |
| `periodic { \|mgr\| mgr.register(...) }` | cron jobs (Enterprise parity, free) |

> ⚠️ **`config.on(:fork)` does not exist** — Wurk's valid lifecycle events are
> `startup, quiet, shutdown, exit, heartbeat, beat, leader`, and `on` raises on
> anything else. Post-fork reconnection is handled automatically by the swarm (it
> closes parent DB/Redis connections before forking and each child opens a fresh
> pool), so you don't register a fork hook yourself.

### Config file

The standalone runner is `bundle exec wurk` (the gem ships a `wurk` executable — there
is **no `sidekiq` binary**, so update any `bundle exec sidekiq` invocations, Procfile
lines, and systemd units to `wurk`). It takes the familiar flags (`-c` concurrency,
`-q` queue, `-r` require, `-t` timeout, `-e` environment, `-C` config), reads a YAML
config with `-C path`, and auto-discovers `config/wurk.yml` then `config/sidekiq.yml`
(`.erb` supported). The YAML structure matches Sidekiq's `sidekiq.yml`.

For running the worker under systemd or capistrano-sidekiq — including an example
unit file and the deploy signal dance — see [`docs/deployment.md`](deployment.md).

---

## 2. Redis key layout: identical, no namespace

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

## 3. `sidekiq_options` mapping

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
| `lock:` | ⚠️ not native | Wurk's native uniqueness uses `unique_for:` / `unique_until:` (below). The `sidekiq-unique-jobs` gem and its `lock:` option run against Wurk in the ecosystem CI suite if you prefer that gem |

Custom retry hooks are unchanged: `sidekiq_retry_in { |count, ex, msg| … }` and
`sidekiq_retries_exhausted { |msg, ex| … }`. The retry backoff formula matches
Sidekiq: `count**4 + 15 + rand(10 * (count + 1))` seconds.

### Pro / Enterprise options (free in Wurk)

- **Unique jobs:** enable with `Sidekiq::Enterprise.unique!`, then
  `sidekiq_options unique_for: 10.minutes, unique_until: :success` (or `:start`).
  *(This is Enterprise's API — not the `sidekiq-unique-jobs` gem's `lock:` DSL.)*
- **Encryption:** `Sidekiq::Enterprise::Crypto.enable(active_version: 1) { |v| key }`,
  then `sidekiq_options encrypt: true` (the last arg is encrypted).
- **Batches:** `Sidekiq::Batch.new` with `on(:success/:complete/:death)`, nesting,
  and `Sidekiq::Batch::Status`.
- **Rate limiters:** `Sidekiq::Limiter.concurrent/bucket/window/leaky/points`.

---

## 4. Known incompatibilities — what *not* to expect

Wurk aims for 100% drop-in. A couple of Sidekiq Pro-isms simply no-op or alias
(items 1–2 — there to reassure, not to fix); the rest are genuine differences worth
knowing. Hit something on a real migration that isn't listed here? **Please open an
issue** — that feedback is part of the v1.0.0 acceptance gate for this guide.

1. **`config.super_fetch!` / `config.reliable_scheduler!` do nothing** (accepted
   no-ops). Wurk's fetcher is *always* reliable (atomic `BLMOVE` to a per-process
   private list, with orphan reclamation) and the scheduler is always atomic, so a
   Sidekiq Pro initializer drops in unchanged — the calls just no-op rather than
   toggling anything. (`Wurk::Client.reliable_push!` also exists for client-side
   buffering during a Redis outage.)
2. **`Sidekiq::Pro::Web` works** — it aliases the same dashboard as `Sidekiq::Web`,
   so `mount Sidekiq::Pro::Web` (or `Sidekiq::Web`, or `Wurk::Engine`) all resolve to
   the wurk dashboard.
3. **`config.workers` / `config.shutdown_timeout` are not Configuration setters.**
   Use `config.concurrency` for threads-per-process and `config[:timeout]` for the
   shutdown grace; process/fork count is governed by the swarm topology
   (`config.topology = Wurk::Topology.flat(count:, queues:, concurrency:)`), not a
   `workers=` accessor.
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

Third-party gems (`sidekiq-cron`, `sidekiq-unique-jobs`, `sidekiq-scheduler`,
`sidekiq-status`, `sidekiq-failures`, `sidekiq-throttled`) are exercised against Wurk
by running their own upstream test suites in the [`ecosystem` CI job](../.github/workflows/ecosystem.yml).

---

## 5. Cutover checklist

1. **Swap the gem** — replace `sidekiq` (+ `sidekiq-pro` / `sidekiq-ent`) with `wurk`
   in the `Gemfile`; `bundle install`.
2. **Keep your config as-is** — Pro toggles like `config.super_fetch!` /
   `config.reliable_scheduler!` are accepted no-ops (already the default), so there's
   nothing to strip out.
3. **Re-point the dashboard route** — `mount Wurk::Engine => "/wurk"` (gate it behind
   your app auth — see [`docs/dashboard.md`](dashboard.md)).
4. **Boot a worker** — `bundle exec wurk` (standalone) or your existing Rails process
   (the engine auto-starts the swarm unless `WURK_DISABLED=1`). Deploying under
   systemd/capistrano? See [`docs/deployment.md`](deployment.md).
5. **Verify on the same Redis** — enqueue a test job, watch it run, and confirm the
   dashboard + your existing `redis-cli` checks look normal. Because the schema is
   shared, you can roll one process at a time.
6. **Roll back anytime** — revert the `Gemfile` line. No schema changes were made.

---

*Found a blocker not covered here? File an issue at
<https://github.com/developerz-ai/wurk/issues> — closing the loop on real migrations
is how this guide earns its v1.0.0 sign-off.*
