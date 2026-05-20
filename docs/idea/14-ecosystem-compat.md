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

## Why this matters

- It's the most credible "100% drop-in" claim possible — verified against real third-party consumers.
- It catches subtle API drift that pure self-tests would miss (private-ish methods third parties came to depend on).
- It surfaces decisions: when a third-party gem relies on Sidekiq internals, we either expose those internals as a public Wurk API or deprecate the dependence with the gem's author.

## Tracking

A status page on the docs site lists every gem in the matrix, its current pass/fail state, and the Wurk version it last passed against. Green badges build trust faster than any benchmark chart.
