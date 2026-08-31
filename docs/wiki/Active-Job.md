# Active Job

Wurk ships an Active Job queue adapter, so mailers, `deliver_later`, Turbo broadcasts and your own `ApplicationJob` subclasses run on Wurk without touching a job class.

```ruby
# config/application.rb
config.active_job.queue_adapter = :wurk
```

Rails resolves `:wurk` to `ActiveJob::QueueAdapters::WurkAdapter` by convention, and the engine loads it eagerly at boot, so no extra `require`. Per-job overrides work as with any adapter:

```ruby
class HardJob < ApplicationJob
  self.queue_adapter = :wurk
  queue_as :critical
end
```

## Already on `:sidekiq`? Change nothing

When the real `sidekiq` gem is **not** in your bundle, Wurk resolves `:sidekiq` to a Wurk-backed adapter too — same enqueue path, same payload. A one-line gem swap keeps a `queue_adapter = :sidekiq` app working untouched.

If the genuine `sidekiq` gem *is* still bundled (a mixed mid-migration setup) Wurk leaves its adapter alone and never clobbers it. So: leave `:sidekiq` for a zero-edit cutover, switch to `:wurk` once Sidekiq is gone. Both run on Wurk.

## Wire compatibility

Jobs are wrapped in `Sidekiq::ActiveJob::Wrapper` before they reach Redis — the canonical `class` string Sidekiq itself writes. Which means:

- Jobs enqueued by stock Sidekiq before the swap deserialize and run on Wurk.
- A mixed pool of Sidekiq and Wurk workers can drain the same Active Job queue.
- The legacy `SidekiqAdapter::JobWrapper` and the old `Wurk::ActiveJob::Wrapper` names both resolve to the same wrapper, so payloads written by any Rails version load after the swap.

`provider_job_id` is the Wurk `jid`, exactly as under Sidekiq.

## Behaviour worth knowing

| Behaviour | Detail |
|---|---|
| **Transaction-safe enqueue** | `enqueue_after_transaction_commit?` is `true` — a job enqueued inside a DB transaction is pushed only once that transaction commits, so you never dispatch a job whose row has not landed. Matches Sidekiq |
| **Bulk enqueue** | `enqueue_all` (Rails 7.1+ `perform_all_later`) groups by class and queue, one `push_bulk` pipeline per group |
| **`sidekiq_options` on AJ classes** | Native Active Job classes gain `sidekiq_options` via `Wurk::Job::Options`, so existing `sidekiq_options retry: 5` config keeps working |
| **Quiet on shutdown** | The adapter's `stopping?` flips on the `:quiet` lifecycle event, so Active Job's own shutdown checks behave as under Sidekiq |

**Gotchas.** Requires `activejob >= 7.0`; if Active Job is not in the bundle the adapter is simply unavailable, no boot error. Active Job serialises arguments through its own `GlobalID` layer, so an object that survived `perform_later` under Sidekiq survives here identically — but a job written against `Wurk::Job` directly does not get that layer, and its arguments must be JSON-native.

Full adapter reference, including the authoritative Sidekiq surface it targets: **[docs/active-job.md](https://github.com/developerz-ai/wurk/blob/main/docs/active-job.md)**.
