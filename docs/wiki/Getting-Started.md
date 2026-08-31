# Getting Started

## Install

```ruby
# Gemfile
gem "wurk"
```

```sh
bundle install
```

That's it — `Sidekiq::Worker`, `Sidekiq::Job`, `Sidekiq::Batch`, `Sidekiq::Limiter`, `Sidekiq.configure_server`, and friends all resolve to Wurk. If you're coming from Sidekiq, see **[[Migrating from Sidekiq]]** for the one-line swap.

## Your first job

```ruby
class HardWorker
  include Sidekiq::Job

  def perform(name, count)
    # ...do the work...
  end
end

HardWorker.perform_async("bob", 5)        # enqueue now
HardWorker.perform_in(5.minutes, "bob", 5) # enqueue later
HardWorker.perform_at(1.hour.from_now, "bob", 5)
```

## Run the workers

Standalone:

```sh
bundle exec wurk
```

Or, in a Rails app, the engine's railtie boots the swarm automatically after initialization (skip it with `WURK_DISABLED=1`, e.g. in the web process).

## Mount the dashboard

```ruby
# config/routes.rb
mount Wurk::Engine => "/wurk"
```

The precompiled SPA ships inside the gem — consumers never run Node. See **[[The Dashboard]]** to gate it behind your app's auth.

## Configure

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.concurrency = 10
  config.queues = %w[critical default low]
end
```

## Next steps

- **[[Periodic, Limiters and Batches]]** — cron, rate limiting, and batches.
- **[[Encryption]]** — encrypt sensitive job arguments.
- **[[Architecture]]** — how the swarm actually runs your jobs.
