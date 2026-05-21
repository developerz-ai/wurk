# frozen_string_literal: true

# Sidekiq aliases. This is the drop-in contract — every public Wurk::*
# class is exposed under its Sidekiq::* name. Never break.
#
# Spec: docs/target/sidekiq-{free,pro,ent}.md.

module Sidekiq
  # Version stamps mirror Sidekiq's OSS release Wurk targets for compat.
  # Third-party gems version-gate on these; raise the MAJOR only when the
  # upstream Sidekiq major bumps and Wurk has matching surface.
  NAME    = 'Sidekiq'
  LICENSE = 'See LICENSE'
  VERSION = '8.1.5'
  MAJOR   = 8

  # Namespace sentinels for Pro/Ent feature subclasses (Sidekiq::Pro::Web,
  # Sidekiq::Enterprise::Crypto, …). Defined so downstream code can nest
  # classes under them — but `Sidekiq.pro?` / `Sidekiq.ent?` still return
  # `false` per docs/target/sidekiq-free.md §32 (Wurk advertises as free OSS).
  module Pro; end

  # Sidekiq Enterprise feature surface (`unique!`, `Crypto`, `Unique.locked?`).
  # Wurk ships these free; the namespace exists for drop-in compat.
  # Implementations live under `Wurk::*`; this module just delegates.
  module Enterprise
    class << self
      # Installs the Wurk::Unique client+server middleware pair globally.
      # Spec: docs/target/sidekiq-ent.md §3.1.
      def unique!
        Wurk::Unique.enable!
      end

      def unique?
        Wurk::Unique.enabled?
      end
    end

    # Wurk::Unique introspection: `Sidekiq::Enterprise::Unique.locked?(...)`.
    # Spec §3.6.
    module Unique
      def self.locked?(*)
        Wurk::Unique.locked?(*)
      end
    end

    # AES-256-GCM args encryption. `Sidekiq::Enterprise::Crypto.enable(...)`
    # delegates to `Wurk::Encryption.enable`. Spec: docs/target/sidekiq-ent.md §4.
    module Crypto
      class << self
        def enable(active_version:, &)
          Wurk::Encryption.enable(active_version: active_version, &)
        end

        def enabled?
          Wurk::Encryption.enabled?
        end
      end
    end
  end

  BasicFetch       = Wurk::Fetcher::Reliable
  Batch            = Wurk::Batch
  BatchSet         = Wurk::BatchSet
  Capsule          = Wurk::Capsule
  CLI              = Wurk::CLI
  Client           = Wurk::Client
  Component        = Wurk::Component
  Config           = Wurk::Configuration
  Context          = Wurk::Context
  Cron             = Wurk::Cron
  Periodic         = Wurk::Cron
  DeadSet          = Wurk::DeadSet
  Embedded         = Wurk::Embedded
  Encryption       = Wurk::Encryption
  IterableJob      = Wurk::IterableJob
  Job              = Wurk::Job
  JobLogger        = Wurk::JobLogger
  JobRecord        = Wurk::JobRecord
  JobRetry         = Wurk::JobRetry
  JobUtil          = Wurk::JobUtil
  Keys             = Wurk::Keys
  Launcher         = Wurk::Launcher
  Limiter          = Wurk::Limiter
  Logger           = Wurk::Logger
  Manager          = Wurk::Manager
  Middleware       = Wurk::Middleware
  ServerMiddleware = Wurk::Middleware::ServerMiddleware
  ClientMiddleware = Wurk::Middleware::ClientMiddleware
  Process          = Wurk::Process
  ProcessSet       = Wurk::ProcessSet
  Processor        = Wurk::Processor
  Queue            = Wurk::Queue
  RetrySet         = Wurk::RetrySet
  Scheduled        = Wurk::Scheduled
  ScheduledSet     = Wurk::ScheduledSet
  Shutdown         = Wurk::Shutdown
  Stats            = Wurk::Stats
  Work             = Wurk::Work
  Worker           = Wurk::Worker
  Workers          = Wurk::Workers
  WorkSet          = Wurk::WorkSet

  # Top-level Sidekiq.configure_server / configure_client / redis / logger
  # delegate to Wurk's class methods. Third-party gems treat these as the
  # canonical entry points.
  class << self
    def configure_server(&) = Wurk.configure_server(&)
    def configure_client(&) = Wurk.configure_client(&)
    def configure_embed(&) = Wurk.configure_embed(&)
    def default_configuration = Wurk.default_configuration
    def redis(&) = Wurk.redis(&)
    def redis_pool = Wurk.redis_pool
    def logger = Wurk.logger
    def server? = Wurk.server?
    def pro? = Wurk.pro?
    def ent? = Wurk.ent?
    def default_job_options = Wurk.default_job_options

    def default_job_options=(hash)
      Wurk.default_job_options = hash
    end

    def strict_args!(mode = :raise) = Wurk.strict_args!(mode)
    def testing!(mode = :fake, &) = Wurk.testing!(mode, &)
    def testing? = Wurk.testing?
    def load_json(str) = Wurk.load_json(str)
    def dump_json(obj) = Wurk.dump_json(obj)
  end
end
