# Wurk ⚡

**A 100% drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise. Free forever. Faster.**

[![Gem Version](https://img.shields.io/gem/v/wurk.svg)](https://rubygems.org/gems/wurk)
[![CI](https://github.com/developerz-ai/wurk/actions/workflows/test.yml/badge.svg)](https://github.com/developerz-ai/wurk/actions/workflows/test.yml)
[![Coverage](https://img.shields.io/badge/coverage-line%20%E2%89%A590%25-brightgreen.svg)](https://github.com/developerz-ai/wurk/actions/workflows/test.yml)
[![Ruby](https://img.shields.io/badge/ruby-%E2%89%A5%203.2-CC342D.svg)](https://www.ruby-lang.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Wurk is wire-compatible with Sidekiq — same Redis keys, same job JSON, same Ruby DSL. Swap one line in your `Gemfile` and your existing jobs, batches, limiters, cron entries, and live Redis data keep working untouched. The Pro and Enterprise feature sets ship in the same free gem, with no license check and no tiers.

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
| **Dashboard** | Mountable Rails engine, precompiled React SPA (no Node needed), live SSE, charts, host-app auth hook | OSS + Pro/Ent |

Plus Wurk extras: a worker topology DSL, a Kubernetes liveness/readiness listener, and opt-in AI dashboard panes (anomaly detection, NL queries, backlog forecasting).

## Documentation

- **[Getting started & architecture](https://github.com/developerz-ai/wurk/blob/main/docs/idea/01-overview.md)** — how the swarm, manager, fetcher, and processor fit together.
- **[Migrating from Sidekiq](#migrating-from-sidekiq)** — the one-line swap and what to expect.
- **API reference (parity specs):** [Sidekiq OSS](https://github.com/developerz-ai/wurk/blob/main/docs/target/sidekiq-free.md) · [Pro](https://github.com/developerz-ai/wurk/blob/main/docs/target/sidekiq-pro.md) · [Enterprise](https://github.com/developerz-ai/wurk/blob/main/docs/target/sidekiq-ent.md) — the authoritative surface Wurk matches exactly.
- **[Securing the dashboard](https://github.com/developerz-ai/wurk/blob/main/docs/dashboard.md)** · **[Metrics history](https://github.com/developerz-ai/wurk/blob/main/docs/metrics-history.md)**
- **Live demo:** [wurk.demo.developerz.ai](https://wurk.demo.developerz.ai)

## Requirements

| Component | Minimum |
|---|---|
| Ruby | `>= 3.2.0` |
| Redis | `>= 7.0.0` |

JRuby, TruffleRuby, and Windows fall back to threads-only mode (no fork) — behaviorally equivalent to stock Sidekiq.

## The dashboard

Mount the engine wherever you like:

```ruby
# config/routes.rb
mount Wurk::Engine => "/wurk"
```

The precompiled SPA ships inside the gem, so consumers never run Node. Gate it behind your app's auth with one line — see **[Securing the dashboard](https://github.com/developerz-ai/wurk/blob/main/docs/dashboard.md)** for Devise/Warden/Sorcery recipes:

```ruby
Wurk::Web.use(Rack::Auth::Basic, "Wurk") { |user, pass| user == ENV["WURK_USER"] && pass == ENV["WURK_PASS"] }
```

Ship a viewer-only board (e.g. a public demo) with no auth code at all by setting `WURK_WEB_READ_ONLY=1` — every mutating request returns 403 and the SPA hides destructive actions.

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

Knobs: `health_check(port:, bind: "0.0.0.0", ready_window: 30)`. In swarm mode only the first child to `start` binds the port.

## Migrating from Sidekiq

```diff
- gem "sidekiq"
- gem "sidekiq-pro", source: "https://gems.contribsys.com/"
- gem "sidekiq-ent", source: "https://enterprise.contribsys.com/"
+ gem "wurk"
```

`bundle install && restart`. Wurk reads and writes the same Redis schema, so a rolling deploy can run Sidekiq and Wurk against the same Redis during the cutover. Third-party gems (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-status, sidekiq-failures, sidekiq-throttled, …) pass their own suites against Wurk.

## Contributing

Issues and pull requests are welcome — see **[CONTRIBUTING.md](https://github.com/developerz-ai/wurk/blob/main/CONTRIBUTING.md)** for the dev setup, test layers, and conventions, and **[SECURITY.md](https://github.com/developerz-ai/wurk/blob/main/SECURITY.md)** to report a vulnerability.

## License

MIT. See [LICENSE](https://github.com/developerz-ai/wurk/blob/main/LICENSE).
