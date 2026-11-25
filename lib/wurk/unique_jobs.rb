# frozen_string_literal: true

require_relative 'lua'
require_relative 'unique_jobs/constants'
require_relative 'unique_jobs/errors'
require_relative 'unique_jobs/reflections'
require_relative 'unique_jobs/job'
require_relative 'unique_jobs/run'
require_relative 'unique_jobs/locksmith'
require_relative 'unique_jobs/on_conflict'
require_relative 'unique_jobs/lock'
require_relative 'unique_jobs/lock_refresh'
require_relative 'unique_jobs/digests'
require_relative 'unique_jobs/middleware'
require_relative 'unique_jobs/orphans'
require_relative 'unique_jobs/config'
require_relative 'unique_jobs/api_extension'

module Wurk
  # sidekiq-unique-jobs 8.x, native: the `lock:` DSL, its options and its global
  # config, on the gem's Redis keys and digest. A lock taken by a process running
  # the gem holds here and the reverse, so a fleet can drop the gem one pod at a
  # time. Exposed as `SidekiqUniqueJobs` when the gem is not in the bundle
  # (`unique_jobs/activation.rb`); with the gem loaded, this stands down.
  #
  # Differences from the gem, none of which change what is in Redis:
  # - Lua that touches only declared keys, so Dragonfly and a strict Redis 7 run it.
  # - A waiting lock blocks on its own connection, not a concurrent-ruby future.
  # - The reaper reads each job once per run, not once per digest, and counts
  #   jobs in wurk's private lists as live (see Orphans::Reaper).
  # - `refresh_lock!` renews a running job's lock (LockRefresh); the gem has none.
  # - No changelog debug logging (`debug_lua`), CLI, upgrade from v6 locks or
  #   version keys: there is nothing to upgrade from.
  module UniqueJobs
    VERSION = '8.1.0'

    class << self
      def config = @config ||= Config.default

      def configure(options = {})
        return yield(config) if block_given?

        options.each { |key, value| config.public_send(:"#{key}=", value) }
      end

      def use_config(tmp_config = {})
        raise ::ArgumentError, "#{name}.use_config needs a block" unless block_given?

        old = config.to_h
        begin
          reset!
          configure(tmp_config)
          yield
        ensure
          reset!
          configure(old)
        end
      end

      def reset! = @config = Config.default
      def logger = config.logger

      def logger=(logger)
        config.logger = logger
      end

      def logging? = config.logger_enabled
      def locks = config.locks
      def strategies = config.strategies
      def version = VERSION
      def enabled? = config.enabled
      def disabled? = !enabled?
      def enable!(&) = toggle(true, &)
      def disable!(&) = toggle(false, &)

      def toggle(enabled)
        return config.enabled = enabled unless block_given?

        was = config.enabled
        config.enabled = enabled
        yield
      ensure
        config.enabled = was if block_given?
      end

      # Pushes out the TTL of the lock `job` holds while it runs: `job` is the
      # running job instance (`self` in `perform`), its jid, or its payload.
      # True when this jid still held the lock (now good for `ttl` seconds, by
      # default the `lock_ttl` it was taken with); false when it no longer did,
      # and then nothing is written. See LockRefresh.
      def refresh_lock!(job, ttl: nil) = LockRefresh.new(job, ttl: ttl).call

      def reflections = @reflections ||= Reflections.new
      def reflect = yield(reflections)
      def redis(&) = Wurk.redis(&)
      def now_f = now.to_f
      def now = ::Time.now

      def validate_worker(options)
        options = deep_stringify(options)
        raise NotUniqueWorker, options unless (lock_type = options[LOCK])

        locks.fetch(lock_type.to_sym).validate_options(options)
      end

      def validate_worker!(options)
        lock_config = validate_worker(options)
        raise InvalidWorker, lock_config unless lock_config.errors.empty?
      end

      # True unless the gem is loaded. Asked per job, and a gem cannot arrive later
      # without raising (unique_jobs/sidekiq_unique_jobs.rb), so a yes is kept.
      def native? = @native ||= !UniqueJobsCompat.gem_present?

      # A native middleware that finds the gem loaded does nothing, so a job is
      # never locked twice, and says so once.
      def warn_standing_down
        return if @stand_down_warned

        @stand_down_warned = true
        logger.warn('Wurk::UniqueJobs middleware is in the chain but the sidekiq-unique-jobs gem is loaded; ' \
                    'the gem locks, the native middleware passes every job through.')
      end

      def constantize(value)
        # A server middleware gets the job instance.
        return value.class if value.class.respond_to?(:get_sidekiq_options)
        return value unless value.is_a?(::String)
        return ::Object.const_get(value) unless value.include?('::')

        value.delete_prefix('::').split('::').inject(::Object) { |mod, name| mod.const_get(name, false) }
      end

      # The class a payload names, or the name itself when it is not loaded.
      def safe_constantize(value)
        constantize(value)
      rescue ::NameError => e
        raise unless e.message.include?('uninitialized constant')

        value
      end

      def deep_stringify(value)
        case value
        when ::Hash then value.to_h { |key, val| [key.to_s, deep_stringify(val)] }
        when ::Array then value.map { |val| deep_stringify(val) }
        else value
        end
      end
    end
  end
end
