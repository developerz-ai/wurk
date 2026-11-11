# frozen_string_literal: true

# Sidekiq aliases. This is the drop-in contract — every public Wurk::*
# class is exposed under its Sidekiq::* name except two deliberate
# exclusions, `Sidekiq::Cron` and `Sidekiq::Status` (#204): those namespaces
# belong to the third-party sidekiq-cron / sidekiq-status gems, not to
# Sidekiq itself. Never break the rest.
#
# Spec: docs/target/sidekiq-{free,pro,ent}.md.

require_relative 'loader'

# The `Sidekiq::*` compatibility namespace. Every public Wurk class is exposed
# here under its Sidekiq name so an existing Sidekiq/Pro/Enterprise app runs on
# Wurk after a one-line gem swap. `Sidekiq::Job` / `Sidekiq::Worker` are
# {Wurk::Job} / {Wurk::Worker}; `Sidekiq.configure_server` is
# {Wurk.configure_server}; `Sidekiq::Batch`, `Sidekiq::Limiter`,
# `Sidekiq::Client`, `Sidekiq::Pro::Web`, `Sidekiq::Enterprise` all resolve to
# their Wurk implementations. This alias surface is the drop-in contract and is
# never broken. Two names are deliberately NOT aliased (#204): `Sidekiq::Cron`
# and `Sidekiq::Status` — those namespaces belong to the third-party
# sidekiq-cron / sidekiq-status gems. `sidekiq-cron` owns `Sidekiq::Cron`, and
# squatting it made the gem's own Poller/Job classes collide at load;
# `sidekiq-status` opens `module Sidekiq::Status`, which resolves the constant
# instead of defining it, so the alias would hand the gem {Wurk::Status} to
# reopen and clobber. The guard comments at `CronParser` and `Status` below
# carry the full rationale.
#
# @example The same code targets Sidekiq or Wurk unchanged
#   class MyJob
#     include Sidekiq::Job
#     def perform(id); end
#   end
#   Sidekiq.configure_server { |c| c.concurrency = 10 }
#
# @note `Sidekiq.pro?` and `Sidekiq.ent?` return `false` — Wurk ships the Pro/Ent
#   features for free but advertises as OSS. Don't gate behavior on them.
# @see https://github.com/developerz-ai/wurk/blob/main/docs/migrate-from-sidekiq.md Migration guide
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

  module RailsNamespace
    Reloader = Wurk::RailsReloader
  end
  private_constant :RailsNamespace

  BasicFetch       = Wurk::Fetcher::Reliable
  Batch            = Wurk::Batch
  BatchSet         = Wurk::BatchSet
  Capsule          = Wurk::Capsule
  Client           = Wurk::Client
  Component        = Wurk::Component
  Config           = Wurk::Configuration
  Context          = Wurk::Context
  DeadSet          = Wurk::DeadSet
  Job              = Wurk::Job
  JobLogger        = Wurk::JobLogger
  JobRecord        = Wurk::JobRecord
  JobRetry         = Wurk::JobRetry
  # sidekiq-unique-jobs reopens these with `class Sidekiq::JobSet` to prepend
  # its lock release; without the alias that defines a fresh, unused class and
  # deleted jobs never give their locks back.
  JobSet           = Wurk::JobSet
  JobUtil          = Wurk::JobUtil
  Keys             = Wurk::Keys
  Limiter          = Wurk::Limiter
  Loader           = Wurk::Loader
  Logger           = Wurk::Logger
  Metrics          = Wurk::Metrics
  Middleware       = Wurk::Middleware
  ServerMiddleware = Wurk::Middleware::ServerMiddleware
  ClientMiddleware = Wurk::Middleware::ClientMiddleware
  Process          = Wurk::Process
  ProcessSet       = Wurk::ProcessSet
  Processor        = Wurk::Processor
  Profiler         = Wurk::Profiler
  Queue            = Wurk::Queue
  RedisClientAdapter = Wurk::RedisClientAdapter
  RedisConnection  = Wurk::RedisConnection
  RetrySet         = Wurk::RetrySet
  ScheduledSet     = Wurk::ScheduledSet
  Shutdown         = Wurk::Shutdown
  SortedEntry      = Wurk::SortedEntry
  SortedSet        = Wurk::SortedSet
  Stats            = Wurk::Stats
  # No `Sidekiq::Status` alias on purpose, same reason as `Sidekiq::Cron`
  # (#204): the sidekiq-status gem owns that namespace and opens it with
  # `module Sidekiq::Status`, which resolves an existing constant rather than
  # defining a fresh module — so the alias would make the gem reopen
  # Wurk::Status and, loading second, silently replace `.get`/`.delete` with its
  # own two-arg-shaped versions while nesting its Storage/Worker/middlewares
  # inside ours. Upstream Sidekiq's only Status is `Sidekiq::Batch::Status`
  # (sidekiq-pro.md §2.5), which *is* aliased; the top-level name is not a
  # Sidekiq surface at all. Wurk's tracking is `Wurk::Status`, reached by name,
  # and its `status:<jid>` rows are disjoint from the gem's `sidekiq:status:<jid>`.
  Testing          = Wurk::Testing
  TransactionAwareClient = Wurk::TransactionAwareClient
  Queues           = Wurk::Queues
  EmptyQueueError  = Wurk::Testing::EmptyQueueError
  Work             = Wurk::Work
  Worker           = Wurk::Worker
  Workers          = Wurk::Workers
  WorkSet          = Wurk::WorkSet

  # Aliases of lazy Wurk constants (Wurk::LazyLoader) are autoloads too, so
  # `defined?(Sidekiq::Web)` holds before the load and the alias is the very
  # object its target is. Each points at a file under lib/wurk/compat/ that
  # loads the target and assigns the alias: the target's own file defines only
  # the Wurk name, so an autoload onto it would leave `Sidekiq::X` undefined.
  # Those files name their targets rather than require them: web.rb, swarm.rb
  # and iterable_job.rb require subfiles that reopen the class before defining
  # it, which a direct require would turn into a circular one.
  #
  # No `Sidekiq::Cron` alias on purpose (#204): real Sidekiq never defines it
  # — that namespace belongs to the third-party sidekiq-cron gem, and squatting
  # it made the gem's own classes (Poller, Job) collide at load. Wurk's native
  # periodic surface is `Sidekiq::Periodic` (Ent parity) / `Wurk::Cron`.
  #
  # `Flow` is a Wurk extra, not parity — aliased because nothing else claims
  # the name. Checked before adding it, the way `Sidekiq::Cron` (#204) and
  # `Sidekiq::Status` taught us to: upstream Sidekiq defines no `Flow` anywhere
  # in `lib/` at the pinned parity SHA, RubyGems has no `sidekiq-flow` or
  # `sidekiq_flow` gem, and the only `Sidekiq::Flow` in public Ruby is a
  # `FlowIdMiddleware` nested under a gem's *own* `Sidekiq` module, which this
  # constant cannot reach.
  Wurk::LazyLoader.register(
    self,
    CLI: 'compat/server', Embedded: 'compat/server', Launcher: 'compat/server',
    Manager: 'compat/server', Scheduled: 'compat/server',
    History: 'compat/server', Periodic: 'compat/server', CronParser: 'compat/server',
    Web: 'compat/web', WebHelpers: 'compat/web', Paginator: 'compat/web',
    ProfileSet: 'compat/profile_set', ProfileRecord: 'compat/profile_set',
    Flow: 'compat/flow', FlowSet: 'compat/flow',
    IterableJob: 'compat/iterable_job', IterableJobQuery: 'compat/iterable_job',
    Deploy: 'compat/deploy', Encryption: 'compat/encryption'
  )
  Wurk::LazyLoader.register(Pro, Web: 'compat/web', BatchStatus: 'compat/web')

  # Top-level Sidekiq.configure_server / configure_client / redis / logger
  # delegate to Wurk's class methods. Third-party gems treat these as the
  # canonical entry points.
  class << self
    def configure_server(&) = Wurk.configure_server(&)
    def configure_client(&) = Wurk.configure_client(&)
    def configure_embed(&) = Wurk.configure_embed(&)
    def default_configuration = Wurk.default_configuration
    def redis(idempotent: false, &) = Wurk.redis(idempotent:, &)
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

    # Answered from const_missing rather than defined as a constant, which would
    # shadow ::Rails for every bare `Rails.logger` written inside `module Sidekiq`.
    def const_missing(name)
      name == :Rails ? RailsNamespace : super
    end

    def gem_version = Gem::Version.new(VERSION)
    def freeze! = Wurk.default_configuration.freeze!
    def strict_args!(mode = :raise) = Wurk.strict_args!(mode)
    def transactional_push! = Wurk.transactional_push!
    def testing!(mode = :fake, &) = Wurk.testing!(mode, &)
    def testing? = Wurk.testing?
    def load_json(str) = Wurk.load_json(str)
    def dump_json(obj) = Wurk.dump_json(obj)
    def loader = Wurk.loader
  end
end

# Upstream fires this at the end of sidekiq/api.rb; Wurk's API is fully loaded
# by the time its aliases are.
Wurk.loader.run_load_hooks(:api)
