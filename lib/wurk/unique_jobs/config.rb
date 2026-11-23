# frozen_string_literal: true

module Wurk
  module UniqueJobs
    # `SidekiqUniqueJobs.configure { |config| ... }`: every knob the gem's
    # Config has, with the gem's defaults, so an existing initializer runs
    # unchanged. `debug_lua`, `locksmith_executor` and the resurrector knobs
    # are accepted and do nothing: the native scripts log nothing and the
    # native locksmith waits on its own connection, with no executor.
    DIGEST_ALGORITHMS = %i[legacy modern].freeze

    Config = ::Struct.new(
      :lock_timeout, :lock_ttl, :enabled, :lock_prefix, :logger, :logger_enabled, :locks, :strategies,
      :debug_lua, :max_history, :reaper, :reaper_count, :reaper_interval, :reaper_timeout,
      :reaper_resurrector_interval, :reaper_resurrector_enabled, :lock_info, :raise_on_config_error,
      :current_redis_version, :digest_algorithm, :locksmith_executor, :on_conflict
    ) do
      def self.default
        new(
          0, nil, true, 'uniquejobs', nil, true, Locks::ALL, OnConflict::STRATEGIES,
          false, 1_000, :ruby, 1_000, 600, 10,
          3600, false, false, false,
          '0.0.0', :legacy, nil, nil
        )
      end

      def logger
        self[:logger] || Wurk.logger
      end

      def digest_algorithm=(value)
        unless DIGEST_ALGORITHMS.include?(value)
          raise ArgumentError, "Invalid digest algorithm: #{value} (should be :modern or :legacy)"
        end

        self[:digest_algorithm] = value
      end

      def add_lock(name, klass)
        sym = name.to_sym
        raise DuplicateLock, ":#{name} already defined, please use another name" if locks.key?(sym)

        self.locks = locks.merge(sym => klass).freeze
      end

      def add_strategy(name, klass)
        sym = name.to_sym
        raise DuplicateStrategy, ":#{name} already defined, please use another name" if strategies.key?(sym)

        self.strategies = strategies.merge(sym => klass).freeze
      end

      def redis_version
        return current_redis_version unless current_redis_version == '0.0.0'

        self.current_redis_version = Wurk.redis { |conn| conn.call('INFO', 'server')[/redis_version:(\S+)/, 1] }
      end

      # The gem names these `default_*`; kept as plain aliases.
      def default_lock_ttl = lock_ttl

      def default_lock_ttl=(value)
        self.lock_ttl = value
      end

      def default_lock_timeout = lock_timeout

      def default_lock_timeout=(value)
        self.lock_timeout = value
      end

      def shutdown_executor; end
    end
  end
end
