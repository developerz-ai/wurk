# Active Job adapter

Wurk ships an Active Job queue adapter, so Rails apps that enqueue through
`ActiveJob::Base` (mailers, `deliver_later`, Turbo broadcasts, your own
`ApplicationJob` subclasses) run on Wurk without touching a single job class.

> Authoritative surface: [`docs/target/sidekiq-free.md`](target/sidekiq-free.md) §28.
> Adapter source: [`lib/active_job/queue_adapters/wurk_adapter.rb`](../lib/active_job/queue_adapters/wurk_adapter.rb).

---

## Enabling it

```ruby
# config/application.rb (or config/environments/*.rb)
config.active_job.queue_adapter = :wurk
```

Rails resolves `:wurk` to `ActiveJob::QueueAdapters::WurkAdapter` by convention.
The engine loads the adapter eagerly at boot, so the constant exists before your
config line runs — no extra `require`.

Per-job overrides work the same as any adapter:

```ruby
class HardJob < ApplicationJob
  self.queue_adapter = :wurk
  queue_as :critical
end
```

---

## Migrating apps already on `:sidekiq`

You don't have to change `queue_adapter = :sidekiq` to flip the switch. When the
real `sidekiq` gem is **not** in your bundle, Wurk resolves `:sidekiq` to a
Wurk-backed adapter as well — same enqueue path, same payload — so a one-line
gem swap keeps a `config.active_job.queue_adapter = :sidekiq` app working
untouched (pillar 1). If the genuine `sidekiq` gem *is* still bundled (a mixed
mid-migration setup), Wurk leaves its adapter alone and never clobbers it.

So: leave `:sidekiq` as-is for a zero-edit cutover, or switch to `:wurk` once
Sidekiq is fully removed. Both run on Wurk.

---

## Wire compatibility

Active Job jobs are wrapped in `Sidekiq::ActiveJob::Wrapper` before they hit
Redis — the canonical `class` string Sidekiq itself writes. That means:

- Jobs enqueued by stock Sidekiq before the swap deserialize and run on Wurk.
- A mixed pool of Sidekiq and Wurk workers can drain the same Active Job queue.
- The legacy `ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper` constant and
  the old `Wurk::ActiveJob::Wrapper` name both resolve to the same wrapper, so
  payloads written by any Rails version load on the gem swap.

The wrapper's `provider_job_id` is set to the Wurk `jid`, so
`job.provider_job_id` works exactly as it does under Sidekiq.

## Behavior worth knowing

| Behavior | Detail |
|---|---|
| **Transaction-safe enqueue** | `enqueue_after_transaction_commit?` is `true`. A job enqueued inside a DB transaction is pushed only after that transaction commits, so you never dispatch a job whose row hasn't landed. Matches Sidekiq. |
| **Bulk enqueue** | `enqueue_all` (Rails 7.1+ `perform_all_later`) groups jobs by class and queue and pushes each group in one `push_bulk` pipeline. |
| **`sidekiq_options` on AJ classes** | Native Active Job classes gain `sidekiq_options` (retry count, queue, etc.) via `Wurk::Job::Options`, so existing `sidekiq_options retry: 5`-style config on an AJ class keeps working. |
| **Quiet on shutdown** | The adapter's `stopping?` flips `true` on the `:quiet` lifecycle event, so Active Job's own shutdown checks behave as under Sidekiq. |

## Requirements

`activejob >= 7.0`. If Active Job isn't in the bundle the adapter is simply
unavailable — same as Sidekiq, no error at boot.
