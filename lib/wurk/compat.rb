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
  module Pro
    # Sidekiq Pro mounts the dashboard at `Sidekiq::Pro::Web`; it's the same
    # board as `Sidekiq::Web` here, so a Pro app's `mount Sidekiq::Pro::Web`
    # drops in unchanged. `Wurk::Web` is already required by the time this file
    # loads (lib/wurk.rb requires wurk/web before wurk/compat).
    Web = Wurk::Web

    # `use Sidekiq::Pro::BatchStatus` — the polling Rack middleware that serves
    # GET /batch_status/<bid>.json. Spec: docs/target/sidekiq-pro.md §10.3.
    BatchStatus = Wurk::Web::BatchStatus

    # Pro module-level statsd accessor (spec §1): `Sidekiq::Pro.dogstatsd = ...`.
    # Delegates to the canonical `config.dogstatsd=` (spec §9.1), so either form
    # feeds the same Wurk::Metrics::Statsd client.
    class << self
      def dogstatsd=(builder)
        Wurk.configuration.dogstatsd = builder
      end

      def dogstatsd
        Wurk.configuration.dogstatsd
      end
    end
  end

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
  Deploy           = Wurk::Deploy
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
  Metrics          = Wurk::Metrics
  Middleware       = Wurk::Middleware
  ServerMiddleware = Wurk::Middleware::ServerMiddleware
  ClientMiddleware = Wurk::Middleware::ClientMiddleware
  Process          = Wurk::Process
  ProcessSet       = Wurk::ProcessSet
  Processor        = Wurk::Processor
  Profiler         = Wurk::Profiler
  ProfileSet       = Wurk::ProfileSet
  ProfileRecord    = Wurk::ProfileRecord
  Queue            = Wurk::Queue
  RedisConnection  = Wurk::RedisConnection
  RetrySet         = Wurk::RetrySet
  Scheduled        = Wurk::Scheduled
  ScheduledSet     = Wurk::ScheduledSet
  Shutdown         = Wurk::Shutdown
  SortedEntry      = Wurk::SortedEntry
  Stats            = Wurk::Stats
  Testing          = Wurk::Testing
  Queues           = Wurk::Queues
  EmptyQueueError  = Wurk::Testing::EmptyQueueError
  Web              = Wurk::Web
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

    def logger=(logger)
      Wurk.logger = logger
    end

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
