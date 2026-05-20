# frozen_string_literal: true

# Sidekiq aliases. This is the drop-in contract — every public Wurk::*
# class is exposed under its Sidekiq::* name. Never break.
#
# Spec: docs/target/sidekiq-{free,pro,ent}.md.

module Sidekiq
end

Sidekiq::IterableJob = Wurk::IterableJob
Sidekiq::Keys        = Wurk::Keys

# TODO: alias every public Wurk constant under Sidekiq, e.g.
#   Sidekiq::Worker      = Wurk::Worker
#   Sidekiq::Job         = Wurk::Job
#   Sidekiq::Client      = Wurk::Client
#   Sidekiq::Batch       = Wurk::Batch
#   Sidekiq::Limiter     = Wurk::Limiter
#   Sidekiq::Cron        = Wurk::Cron
#   Sidekiq::Queue       = Wurk::Queue
#   Sidekiq::RetrySet    = Wurk::RetrySet
#   Sidekiq::ScheduledSet = Wurk::ScheduledSet
#   Sidekiq::DeadSet     = Wurk::DeadSet
#   Sidekiq::Stats       = Wurk::Stats
#   Sidekiq.configure_server { ... } / configure_client { ... } / redis { ... }
# Match docs/target/*.md exactly.
