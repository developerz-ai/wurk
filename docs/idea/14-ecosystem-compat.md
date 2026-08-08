# Ecosystem Compatibility

Drop-in for Sidekiq is not just the Sidekiq gem itself. A 100% drop-in claim means the **Sidekiq ecosystem** of third-party gems built on top of Sidekiq's API also works unchanged against Wurk.

This is testable, and it's the strongest possible proof of compat.

## What we test against

The gems below are widely used and depend on Sidekiq's public surface in ways that exercise different parts of the API. If they work, Wurk is genuinely drop-in.

| Gem | What it exercises |
|---|---|
| sidekiq-cron | Periodic jobs built on Sidekiq scheduler — uses Sidekiq::Worker, scheduler enqueue, Web UI extension hooks |
| sidekiq-unique-jobs | Unique-job middleware — exercises client and server middleware chains, sidekiq_options |
| sidekiq-scheduler | Alternative scheduler — exercises Sidekiq.configure_server, internal API |
| sidekiq-status | Job status tracking — middleware chains, Sidekiq::Worker hooks |
| sidekiq-failures | Failure tracker — Sidekiq::Failures hook, Web UI extension |
| sidekiq-throttled | Throttling middleware — server middleware, fetcher hooks |
| sidekiq-batch (the OSS one) | Batches without paying Pro — Redis key schema |
| activejob-uniqueness | ActiveJob layer uniqueness — verifies the ActiveJob adapter shape |
| sidekiq-pro-like gems / sidekiq-grouping | Bulk patterns — client middleware, Redis bulk ops |

This list grows over time. New ecosystem gems are added when they demonstrate Wurk is missing a Sidekiq behavior.

## How we test

A dedicated CI job runs each ecosystem gem's own test suite **against Wurk** instead of Sidekiq. Mechanism:

- A small wrapper sets up a bundle with the ecosystem gem and points it at Wurk via the same require alias trick that makes Wurk drop-in for end users.
- The wrapper runs the gem's published test suite.
- The job passes only if the suite passes unchanged.

If a gem's suite fails, the failure is the spec — we either fix Wurk to match Sidekiq's behavior the gem relies on, or document the divergence as an intentional incompatibility (rare and a last resort).

A harness is added to `test/ecosystem/` only when it is green. `test:ecosystem` is a required check, so a harness that cannot pass yet is a permanent red on every PR in the repo — it blocks unrelated work and trains everyone to ignore the signal. Until the gap is closed, the pin and the exact blocker live here instead.

## Not yet in the matrix — pin researched, blocker known

### sidekiq-status

**Pin:** `kenaniah/sidekiq-status` v4.0.0 (`af8e633d5771901f5ef4eedafe7a239a2209b115`). Not `utgarda/sidekiq-status`: that repo is archived, its last release (v1.1.4, 2019) drives Sidekiq-5 APIs Sidekiq 7 removed (`Sidekiq.options`, `Sidekiq::RedisConnection.create`, `Sidekiq::CLI.instance.run`), and it fails against real modern Sidekiq too — so it cannot be an oracle for Wurk. Development moved to the fork, whose gemspec pins `sidekiq >= 7, < 9`: exactly the release the shim gem reports. Its Rakefile aliases `task :test => :spec`, so the harness's plain `rake test` works.

**Blocker:** `lib/sidekiq-status/web.rb` mutates `Sidekiq::WebHelpers::SAFE_QPARAMS` at load, and its `web_spec.rb` drives `Sidekiq::Web` through rack-test expecting ERB-rendered HTML. Wurk's dashboard is a precompiled SPA plus a JSON API (`docs/idea/08-dashboard.md`) and exposes a deliberate subset of the helper surface as `Wurk::Web::Extension::Helpers`, not `Sidekiq::WebHelpers`. Closing this is a Web-surface decision, not a shim: land it with the job-status slice that needs the suite.

Already closed by this work: `require "sidekiq/processor"`, `"sidekiq/manager"` and `"sidekiq/job_retry"` — all three are real upstream files this suite requires, and all three now resolve (`lib/sidekiq/`, pinned by `test/unit/sidekiq_entrypoint_test.rb`).

### sidekiq-unique-jobs

**Pin:** `mhenrixon/sidekiq-unique-jobs` v8.1.0 (`4e57de89f3ac817b876c6b5d57050e05accad2d6`).

**Blockers**, all in the harness contract rather than in Wurk:

- The suite needs a **Toxiproxy service container** (`ghcr.io/shopify/toxiproxy`, ports 8474/21212) alongside Redis; `spec/spec_helper.rb` requires `toxiproxy` at load. `.github/workflows/ecosystem.yml` declares only Redis.
- `spec_helper.rb` hardcodes `config.redis = { port: 6379 }` (DB 0), ignoring `ECOSYSTEM_REDIS_URL` — it would trash whatever lives in DB 0 rather than the harness's DB 15.
- Its `rake rspec` task hardcodes `--format Fuubar --format Nc`, formatters upstream installs only on darwin. Upstream CI never runs that task; it runs `bin/rspec --require spec_helper --tag ~perf`. So the harness needs a **command** escape hatch, not the rake-task name one — the `TASK` file this repo briefly carried would not have run this suite either.
- The gemspec declares no development dependencies, so an overlay `gemspec path:` alone leaves `rake`, `rspec`, `rspec-its`, `timecop` and `toxiproxy` out of the bundle; the overlay has to mirror the upstream Gemfile's test deps explicitly.

## Why this matters

- It's the most credible "100% drop-in" claim possible — verified against real third-party consumers.
- It catches subtle API drift that pure self-tests would miss (private-ish methods third parties came to depend on).
- It surfaces decisions: when a third-party gem relies on Sidekiq internals, we either expose those internals as a public Wurk API or deprecate the dependence with the gem's author.

## Tracking

A status page on the docs site lists every gem in the matrix, its current pass/fail state, and the Wurk version it last passed against. Green badges build trust faster than any benchmark chart.
