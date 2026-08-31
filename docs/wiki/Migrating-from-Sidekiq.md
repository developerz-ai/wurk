# Migrating from Sidekiq

```diff
- gem "sidekiq"
- gem "sidekiq-pro", source: "https://gems.contribsys.com/"
- gem "sidekiq-ent", source: "https://enterprise.contribsys.com/"
+ gem "wurk"
```

Then `bundle install && restart`. That's it.

## Why it just works

Wurk reads and writes the **same Redis schema** Sidekiq does — same keys, same job JSON, same sorted-set score formats. So:

- Jobs already enqueued under Sidekiq run on Wurk unchanged.
- A rolling deploy can run Sidekiq and Wurk against the **same Redis** during the cutover.
- Every public `Wurk::*` class is exposed under its `Sidekiq::*` name, so `Sidekiq::Worker`, `Sidekiq::Batch`, `Sidekiq::Limiter`, `Sidekiq.configure_server`, etc. all resolve.

## Third-party gems

Ecosystem gems (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-status, sidekiq-failures, sidekiq-throttled, …) are exercised by running their own upstream suites against Wurk in CI.

## What about Pro / Enterprise features?

They're built in — batches, rate limiters, periodic jobs, unique jobs, encryption, multi-process swarm, rolling restarts — in the same free gem, no license check. Drop the `sidekiq-pro` / `sidekiq-ent` gem lines and keep your code.
