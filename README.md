<p align="center">
  <img src="https://raw.githubusercontent.com/developerz-ai/wurk/main/docs/assets/wurk-logo.png" alt="Wurk — an orc ready to work" width="220">
</p>

<h1 align="center">Wurk ⚡</h1>

<p align="center"><strong>Wurk, wurk.</strong> 🪓 <em>Ready to work. Zug zug.</em></p>

<p align="center"><strong>A 100% drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise. Free forever.</strong></p>

<div align="center">

[![Live Demo](https://img.shields.io/badge/live%20demo-wurk.demo.developerz.ai-22c55e?logo=googlechrome&logoColor=white)](https://wurk.demo.developerz.ai/wurk)
[![Gem Version](https://img.shields.io/gem/v/wurk.svg)](https://rubygems.org/gems/wurk)
[![CI](https://github.com/developerz-ai/wurk/actions/workflows/test.yml/badge.svg)](https://github.com/developerz-ai/wurk/actions/workflows/test.yml)
[![Coverage gate](https://img.shields.io/badge/coverage%20gate-line%20%E2%89%A590%25-brightgreen.svg)](https://github.com/developerz-ai/wurk/actions/workflows/test.yml)
[![Ruby](https://img.shields.io/badge/ruby-%E2%89%A5%203.2-CC342D.svg)](https://www.ruby-lang.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

</div>

Wurk is wire-compatible with Sidekiq — same Redis keys, same job JSON, same Ruby DSL. Swap one line in your `Gemfile` and your existing jobs, batches, limiters, cron entries, and live Redis data keep working untouched. The Pro and Enterprise feature sets ship in the same free gem, with no license check and no tiers.

**On speed:** Wurk is not currently faster than stock Sidekiq — it runs at roughly 0.87×–0.99× depending on workload shape, with parity on CPU and I/O but still behind on framework overhead (noop) and boot time. Numbers, method, and the reproduction command are in [docs/benchmarks.md](docs/benchmarks.md); run them yourself with `rake bench:vs_sidekiq`.

## Install

```ruby
# Gemfile
gem "wurk"
```

```diff
# ...or drop in over an existing Sidekiq stack — delete these, add one line:
- gem "sidekiq"
- gem "sidekiq-pro", source: "https://gems.contribsys.com/"
- gem "sidekiq-ent", source: "https://enterprise.contribsys.com/"
+ gem "wurk"
```

`bundle install && restart`. That's it — `Sidekiq::Worker`, `Sidekiq::Batch`, `Sidekiq::Limiter`, `Sidekiq.configure_server`, and friends all resolve to Wurk.

## Feature matrix

Everything below is in the one free gem. The "Sidekiq tier" column is only there to show what you'd otherwise pay for.

| Area | What you get | Sidekiq tier |
|---|---|---|
| **Runtime** | Fork-based real parallelism, reliable `BLMOVE` fetch, PID supervision, rolling restarts, graceful drain, scheduled/retry pollers | OSS + Pro |
| **Batches** | `Sidekiq::Batch` with `on(:success/:complete/:death)` callbacks, nested batches, progress | Pro |
| **Limiters** | Concurrent, bucket, window, leaky, and points rate limiters via `Sidekiq::Limiter` | Enterprise |
| **Periodic** | Cron/periodic jobs, leader-elected so each tick fires exactly once across the cluster | Enterprise |
| **Encryption** | Transparent AES-256-GCM job-argument encryption with zero-downtime key rotation | Enterprise |
| **Dashboard** | Mountable Rails engine, precompiled SolidJS SPA (no Node needed), live SSE, charts, host-app auth hook | OSS + Pro/Ent |

Plus Wurk extras: a worker topology DSL, a Kubernetes liveness/readiness listener, and opt-in AI dashboard panes (anomaly detection, NL queries, backlog forecasting).

## Documentation

- **[Website](https://developerz-ai.github.io/wurk/)** · **[Wiki / full docs](https://github.com/developerz-ai/wurk/wiki)** — the pitch, install, and the complete guide.
- **[API reference (YARD)](https://developerz-ai.github.io/wurk/api/)** — generated docs for the public classes (`Wurk::Worker`, `Wurk::Client`, `Wurk::Configuration`, `Wurk::Batch`, `Wurk::Limiter`, `Wurk::Unique`, and the `Sidekiq::*` aliases). Machine-readable map for AI agents: **[llms.txt](https://developerz-ai.github.io/wurk/llms.txt)**.
- **[Getting started & architecture](https://github.com/developerz-ai/wurk/blob/main/docs/idea/01-overview.md)** — how the swarm, manager, fetcher, and processor fit together.
- **[Starting the worker](https://github.com/developerz-ai/wurk/blob/main/docs/running.md)** — Rails auto-start, the `wurk`/`wurkswarm` runners, and running standalone without Rails.
- **[Configuration reference](https://github.com/developerz-ai/wurk/blob/main/docs/configuration.md)** — every option, env var, YAML key, and CLI flag, with precedence and pool sizing.
- **[Deploying](https://github.com/developerz-ai/wurk/blob/main/docs/deployment.md)** — systemd, Capistrano, Heroku, Docker, Kubernetes, rolling restarts, memory limits.
- **[Secrets & credentials](https://github.com/developerz-ai/wurk/blob/main/docs/secrets.md)** — which values are secret vs config, how to supply them (ENV, Rails credentials, an init file), precedence, and what to never commit.
- **[Active Job adapter](https://github.com/developerz-ai/wurk/blob/main/docs/active-job.md)** — run `ActiveJob`/`deliver_later` on Wurk with `queue_adapter = :wurk`.
- **[Testing jobs](https://github.com/developerz-ai/wurk/blob/main/docs/testing.md)** — fake/inline modes, the jobs array, Minitest and RSpec setup.
- **[Migrating from Sidekiq](#migrating-from-sidekiq)** — the one-line swap and what to expect.

**Features:**

- **[Retries, backoff & the dead set](https://github.com/developerz-ai/wurk/blob/main/docs/retries.md)** · **[Reliability](https://github.com/developerz-ai/wurk/blob/main/docs/reliability.md)** — the failure lifecycle, and the delivery guarantee with its limits.
- **[Batches](https://github.com/developerz-ai/wurk/blob/main/docs/batches.md)** · **[Rate limiting](https://github.com/developerz-ai/wurk/blob/main/docs/rate-limiting.md)** · **[Periodic (cron) jobs](https://github.com/developerz-ai/wurk/blob/main/docs/periodic-jobs.md)** · **[Unique jobs](https://github.com/developerz-ai/wurk/blob/main/docs/unique-jobs.md)** — the Pro/Ent features, free.
- **[Iterable jobs](https://github.com/developerz-ai/wurk/blob/main/docs/iterable-jobs.md)** · **[Middleware](https://github.com/developerz-ai/wurk/blob/main/docs/middleware.md)** · **[Encryption](https://github.com/developerz-ai/wurk/blob/main/docs/encryption.md)** · **[Profiling](https://github.com/developerz-ai/wurk/blob/main/docs/profiling.md)**
- **[Data API](https://github.com/developerz-ai/wurk/blob/main/docs/api.md)** · **[Metrics](https://github.com/developerz-ai/wurk/blob/main/docs/metrics.md)** — inspect queues and jobs from Ruby; job metrics, Statsd/DogStatsD, custom history.
- **[Sentry](https://github.com/developerz-ai/wurk/blob/main/docs/sentry.md)** — built-in error reporting (`sentry-sidekiq` can't be installed alongside Wurk); terminal-failure-only reports, per-job scope, no job args.
- **API reference (parity specs):** [Sidekiq OSS](https://github.com/developerz-ai/wurk/blob/main/docs/target/sidekiq-free.md) · [Pro](https://github.com/developerz-ai/wurk/blob/main/docs/target/sidekiq-pro.md) · [Enterprise](https://github.com/developerz-ai/wurk/blob/main/docs/target/sidekiq-ent.md) — the authoritative surface Wurk matches exactly.
- **[Authentication & authorization](https://github.com/developerz-ai/wurk/blob/main/docs/authentication.md)** — gate the dashboard behind Devise/Warden, Sorcery, Basic auth, or a token; role-based read/write; CSRF.
- **[Securing the dashboard](https://github.com/developerz-ai/wurk/blob/main/docs/dashboard.md)** · **[Metrics history](https://github.com/developerz-ai/wurk/blob/main/docs/metrics-history.md)**
- **[Compatibility & legal basis](https://github.com/developerz-ai/wurk/blob/main/docs/clean-room.md)** — clean-room implementation: Wurk copies the API, not the code (Google v. Oracle).
- **Live demo:** [wurk.demo.developerz.ai](https://wurk.demo.developerz.ai)

## Requirements

| Component | Minimum |
|---|---|
| Ruby | `>= 3.2.0` |
| Redis | `>= 7.0.0` |

JRuby, TruffleRuby, and Windows fall back to threads-only mode (no fork) — behaviorally equivalent to stock Sidekiq.

## Running the workers

Under Rails the engine **auto-starts** the swarm on boot — a plain `rails server` already forks workers and fetches. Set `WURK_DISABLED=1` on any process that shouldn't (e.g. the web tier when you run workers on their own dyno).

**One exception — preforking web servers.** A clustered Puma, Unicorn, or Passenger forks its own web workers, so Wurk **refuses** to also fork the swarm there — it would multiply the swarm by the web-worker count, or entangle its supervisor with the server's own fork/signal handling — and logs how to proceed. Either run the swarm as its own process (recommended):

```bash
bundle exec wurkswarm   # forked swarm, real parallelism
```

…or run it inside the web process as threads only, no fork (like Sidekiq embedded):

```ruby
# config/application.rb  (here, not an initializer — server mode is decided before initializers load)
config.wurk.embed_in_web = true
```

Single-mode Puma (the `rails server` default) isn't preforking, so auto-start is unaffected. Full details, flags, and the standalone runners: **[Starting the worker](https://github.com/developerz-ai/wurk/blob/main/docs/running.md)**.

## The dashboard

Mount the engine wherever you like:

```ruby
# config/routes.rb
mount Wurk::Engine => "/wurk"
```

On Devise, wrap it in `authenticate` so only signed-in admins reach it — unauthenticated visitors get bounced to your login page:

```ruby
# config/routes.rb
authenticate :user, ->(u) { u.admin? } do
  mount Wurk::Engine => "/wurk"
end
```

The precompiled SPA ships inside the gem, so consumers never run Node. Outside Rails routing — or when you'd rather keep auth next to the rest of your Wurk config — gate it with any Rack middleware; see **[Authentication & authorization](https://github.com/developerz-ai/wurk/blob/main/docs/authentication.md)** for Devise/Warden/Sorcery/token recipes, role-based read/write splits, and the CSRF model:

```ruby
Wurk::Web.use(Rack::Auth::Basic, "Wurk") { |user, pass| user == ENV["WURK_USER"] && pass == ENV["WURK_PASS"] }
```

Ship a viewer-only board (e.g. a public demo) with no auth code at all by setting `WURK_WEB_READ_ONLY=1` — every mutating request returns 403 and the SPA hides destructive actions.

### Security notes

- **`Wurk::Web.use` and the `authorization` hook gate the dashboard's routes and JSON API** — every controller under the engine mount goes through them.
- **`/wurk-assets/*` (the precompiled SPA's JS/CSS/font bundle) is served unauthenticated, by design.** It's inserted into the host app's own middleware stack ahead of the engine's routes, so it never reaches `Wurk::Web.use`/`authorization`. This is safe because the bundle carries no data — no job payloads, no Redis reads, nothing per-user — it's a static shell, same trust model as any Rails app's `public/assets`. Everything data-bearing (stats, queues, jobs) is served by the JSON API, which *is* gated. If you need to hide even the existence of the bundle (e.g. compliance requires the mount path itself stay secret), put a reverse-proxy rule in front of `/wurk-assets` rather than relying on the engine.
- Redis being unreachable surfaces to the SPA as a structured `503 {"error": "redis_unavailable"}` (JSON endpoints) or an SSE `error` event (the live stream), never a raw 500 — the client can branch on it instead of parsing an HTML error page.

## Encryption

A drop-in for `Sidekiq::Enterprise::Crypto`. It encrypts the **last** positional argument of a job with AES-256-GCM — the client middleware seals it on push, the server middleware opens it before `perform`. Earlier args stay plaintext so you can still triage on `user_id`.

```ruby
# config/initializers/wurk.rb — point at any key source (file, ENV, KMS)
Sidekiq::Enterprise::Crypto.enable(active_version: 1) do |version|
  File.binread("config/crypto/secret.#{Rails.env}.#{version}.key") # exactly 32 bytes
end
```

```ruby
class ChargeCardJob
  include Sidekiq::Job
  sidekiq_options encrypt: true

  def perform(user_id, secret_bag) # secret_bag arrives already decrypted
    Payments.charge(user_id, secret_bag["pan"], secret_bag["cvv"])
  end
end
```

Keys rotate without downtime — keep every still-in-flight version resolvable so old jobs decrypt, then bump `active_version`. A job that can't be decrypted (key rotated away, corrupt ciphertext) goes **straight to the dead set in under a second** rather than crash-looping through 25 retries, with the still-encrypted payload preserved for replay. The dashboard renders encrypted args as `"<encrypted>"`; cleartext is never written to Redis.

## Kubernetes probes

Opt in to a thin HTTP listener for liveness/readiness:

```ruby
Wurk.configure_server do |config|
  config.health_check(port: 7433)
end
```

| Path | Meaning |
|---|---|
| `/live` | 200 while the Launcher is running; 503 once `stop`/`quiet` is called. |
| `/ready` | 200 only when Redis is reachable **and** the heartbeat fired within `ready_window` (default 30s); 503 otherwise. |

Knobs: `health_check(port:, bind: "0.0.0.0", ready_window: 30)`. In swarm mode one child owns the port; the others poll every 5s and take it over if the owner dies, so probes survive a child restart.

## Migrating from Sidekiq

```diff
- gem "sidekiq"
- gem "sidekiq-pro", source: "https://gems.contribsys.com/"
- gem "sidekiq-ent", source: "https://enterprise.contribsys.com/"
+ gem "wurk"
```

`bundle install && restart`. Wurk reads and writes the same Redis schema, so a rolling deploy can run Sidekiq and Wurk against the same Redis during the cutover. Third-party gems (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-status, sidekiq-failures, sidekiq-throttled, …) are exercised by running their own upstream suites against Wurk in the [`ecosystem` CI job](https://github.com/developerz-ai/wurk/blob/main/.github/workflows/ecosystem.yml) (see [`test/ecosystem/`](https://github.com/developerz-ai/wurk/tree/main/test/ecosystem)).

Full walkthrough — config side-by-side, the Redis key/`sidekiq_options` mapping, known incompatibilities, and a one-page cutover checklist: **[docs/migrate-from-sidekiq.md](https://github.com/developerz-ai/wurk/blob/main/docs/migrate-from-sidekiq.md)**.

## Contributing

Issues and pull requests are welcome — see **[CONTRIBUTING.md](https://github.com/developerz-ai/wurk/blob/main/CONTRIBUTING.md)** for the dev setup, test layers, and conventions, and **[SECURITY.md](https://github.com/developerz-ai/wurk/blob/main/SECURITY.md)** to report a vulnerability.

## License

MIT. See [LICENSE](https://github.com/developerz-ai/wurk/blob/main/LICENSE).

Wurk is a clean-room reimplementation of the Sidekiq **API** — it copies the
interface (so your jobs run unchanged), not Sidekiq's implementation code. This
is the same basis the Supreme Court upheld for Google's reuse of the Java API in
*Google v. Oracle* (2021). "Sidekiq" is a trademark of Contributed Systems, LLC;
Wurk is independent and not affiliated with or endorsed by them. Full reasoning:
**[docs/clean-room.md](https://github.com/developerz-ai/wurk/blob/main/docs/clean-room.md)**.
