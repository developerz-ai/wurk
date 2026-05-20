# frozen_string_literal: true

# Sidekiq aliases. This is the drop-in contract — every public Wurk::*
# class is exposed under its Sidekiq::* name. Never break.
#
# Spec: docs/target/sidekiq-{free,pro,ent}.md.

module Sidekiq
end

Sidekiq::Batch       = Wurk::Batch
Sidekiq::Client      = Wurk::Client
Sidekiq::Context     = Wurk::Context
Sidekiq::Cron        = Wurk::Cron
Sidekiq::DeadSet     = Wurk::DeadSet
Sidekiq::IterableJob = Wurk::IterableJob
Sidekiq::Job         = Wurk::Job
Sidekiq::JobLogger   = Wurk::JobLogger
Sidekiq::JobRecord   = Wurk::JobRecord
Sidekiq::JobRetry    = Wurk::JobRetry
Sidekiq::Keys        = Wurk::Keys
Sidekiq::Launcher    = Wurk::Launcher
Sidekiq::Limiter     = Wurk::Limiter
Sidekiq::Logger      = Wurk::Logger
Sidekiq::Manager     = Wurk::Manager
Sidekiq::Middleware  = Wurk::Middleware
Sidekiq::ServerMiddleware = Wurk::Middleware::ServerMiddleware
Sidekiq::ClientMiddleware = Wurk::Middleware::ClientMiddleware
Sidekiq::Process     = Wurk::Process
Sidekiq::ProcessSet  = Wurk::ProcessSet
Sidekiq::Processor   = Wurk::Processor
Sidekiq::Queue       = Wurk::Queue
Sidekiq::RetrySet    = Wurk::RetrySet
Sidekiq::ScheduledSet = Wurk::ScheduledSet
Sidekiq::Stats       = Wurk::Stats
Sidekiq::Work        = Wurk::Work
Sidekiq::Worker      = Wurk::Worker
Sidekiq::Workers     = Wurk::Workers
Sidekiq::WorkSet     = Wurk::WorkSet

# Top-level Sidekiq.configure_server / configure_client / redis / logger
# delegate to Wurk's class methods. Third-party gems treat these as the
# canonical entry points.
module Sidekiq
  class << self
    def configure_server(&) = Wurk.configure_server(&)
    def configure_client(&) = Wurk.configure_client(&)
    def redis(&) = Wurk.redis(&)
    def logger = Wurk.logger
    def server? = Wurk.server?
    def pro? = Wurk.pro?
    def ent? = Wurk.ent?
    def default_job_options = Wurk.default_job_options

    def default_job_options=(hash)
      Wurk.default_job_options = hash
    end

    def strict_args!(mode = :raise) = Wurk.strict_args!(mode)
    def load_json(str) = Wurk.load_json(str)
    def dump_json(obj) = Wurk.dump_json(obj)
  end
end
