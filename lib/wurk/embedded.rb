# frozen_string_literal: true

require_relative 'component'
require_relative 'launcher'

module Wurk
  # Embeds Wurk inside an arbitrary Ruby process (Puma, rake task, custom
  # daemon) without forking a swarm. Same Launcher/Manager/Processor stack
  # the CLI uses — only the parent-process supervision is skipped.
  #
  # Typical use:
  #   instance = Wurk.configure_embed { |c| c.queues = %w[critical default] }
  #   instance.run
  #   # ... host process serves traffic ...
  #   instance.stop
  #
  # Concurrency defaults to 2 (set in `Wurk.configure_embed`) because the GIL
  # makes contention worse in a host process that already has its own thread
  # pool. The heartbeat marks `embedded: true` so the dashboard distinguishes
  # embedded workers from swarm-forked workers.
  #
  # Spec: docs/target/sidekiq-free.md §22 (Sidekiq::Embedded).
  class Embedded
    include Component

    attr_reader :launcher

    def initialize(config)
      @config = config
      @launcher = nil
    end

    # Validates Redis, fires :startup, boots the launcher, sleeps 0.2 so
    # the worker threads have time to spin up before the host goes back to
    # serving traffic. Mirrors Sidekiq::Embedded#run.
    def run
      housekeeping
      fire_event(:startup, reverse: false, reraise: true)
      @launcher = build_launcher
      @launcher.run
      sleep 0.2
      logger.info { "Wurk running embedded, total process thread count: #{Thread.list.size}" }
      logger.debug { Thread.list.map(&:name).to_s }
    end

    # Stop fetching new work; in-flight jobs continue.
    def quiet
      @launcher&.quiet
    end

    # Graceful drain inside config[:timeout]; cancels in-flight jobs that
    # exceed the deadline.
    def stop
      @launcher&.stop
    end

    private

    # Extracted so tests can swap in a fake launcher without monkey-patching
    # Wurk::Launcher.new globally (which races other parallel tests).
    def build_launcher
      Launcher.new(@config, embedded: true)
    end

    # Same checks Wurk::CLI performs before launch: tag default, Redis
    # version floor, maxmemory-policy advisory. We intentionally do NOT
    # run validate_pool_sizes! — the host owns its connection pools and
    # may legitimately undersize for embedded workloads.
    def housekeeping
      @config[:tag] ||= default_tag
      logger.info "Running in #{RUBY_DESCRIPTION}"
      validate_redis!
    end

    def validate_redis!
      info = @config.redis_pool.info
      ver = ::Gem::Version.new(info['redis_version'])
      if ver < ::Gem::Version.new(CLI::MIN_REDIS_VERSION)
        raise "You are connected to Redis #{ver}, Wurk requires Redis #{CLI::MIN_REDIS_VERSION} or greater"
      end

      policy = info['maxmemory_policy']
      return if policy.nil? || policy.empty? || policy == 'noeviction'

      logger.warn { <<~WARN }


        WARNING: Your Redis instance will evict Wurk data under heavy load.
        The 'noeviction' maxmemory policy is recommended (current policy: '#{policy}').

      WARN
    end
  end
end
