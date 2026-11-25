# frozen_string_literal: true

module Wurk
  module UniqueJobs
    # A digest's lock as it sits in Redis, for inspection and the dashboard; and
    # the namespace of the lock types, as in the gem.
    class Lock
      attr_reader :key

      def initialize(key, time: nil)
        @key = key.is_a?(Key) ? key : Key.new(key)
        time = time.to_f
        @created_at = time unless time.zero?
      end

      # The Locks page's two reads per row (the info and the locked count), for
      # a whole page in one round trip.
      def self.preload(locks)
        return locks if locks.empty?

        replies = UniqueJobs.redis do |conn|
          conn.pipelined do |pipe|
            locks.each do |lock|
              pipe.call('GET', lock.key.info)
              pipe.call('HLEN', lock.key.locked)
            end
          end
        end
        locks.zip(replies.each_slice(2)) { |lock, (info, count)| lock.preloaded(info, count) }
        locks
      end

      def preloaded(raw_info, locked_count)
        @info = LockInfo.new(key.info).preloaded(raw_info)
        @locked = LockedJids.new(key.locked, count: locked_count)
      end

      def created_at = @created_at ||= changelogs.first&.fetch('time', nil)
      def all_jids = (queued_jids + primed_jids + locked_jids).uniq
      def queued_jids = UniqueJobs.redis { |conn| conn.call('LRANGE', key.queued, 0, -1) }
      def primed_jids = UniqueJobs.redis { |conn| conn.call('LRANGE', key.primed, 0, -1) }

      def locked_jids(with_values: false)
        entries = UniqueJobs.redis { |conn| conn.call('HGETALL', key.locked) }
        entries = entries.each_slice(2).to_h if entries.is_a?(::Array)
        with_values ? entries : entries.keys
      end

      def info = @info ||= LockInfo.new(key.info)
      def locked = @locked ||= LockedJids.new(key.locked)
      def changelog = @changelog ||= Changelog.new
      def changelogs = changelog.entries(pattern: "*#{key.digest}*")

      # Drops one jid from the LOCKED hash, as the dashboard's per-job delete does.
      def unlock(job_id) = UniqueJobs.redis { |conn| conn.call('HDEL', key.locked, job_id) }

      def del
        UniqueJobs.redis do |conn|
          conn.multi do |tx|
            tx.call('ZREM', DIGESTS, key.digest)
            tx.call('DEL', key.digest, key.queued, key.primed, key.locked, key.info)
          end
        end
      end

      def to_s
        "Lock status for #{key}\n  queued_jids: #{queued_jids}\n  primed_jids: #{primed_jids}\n  " \
          "locked_jids: #{locked_jids}\n  info: #{info.value}"
      end
      alias inspect to_s

      # `<digest>:INFO`, the JSON `lock_info: true` writes.
      class LockInfo
        def initialize(key)
          @key = key
        end

        def value
          return @value if defined?(@value)

          preloaded(UniqueJobs.redis { |conn| conn.call('GET', @key) })
          @value
        end

        def preloaded(raw)
          @value = raw.nil? || raw.empty? ? nil : Wurk.load_json(raw)
          self
        end

        def none? = value.nil? || value.empty?
        def present? = !none?
        def [](field) = value.is_a?(::Hash) ? value[field.to_s] : nil
      end

      # `<digest>:LOCKED`, as the dashboard counts it.
      class LockedJids
        def initialize(key, count: nil)
          @key = key
          @count = count
        end

        def count = @count || UniqueJobs.redis { |conn| conn.call('HLEN', @key) }
      end

      # One lock type: the client side (`#lock`) and the server side (`#execute`).
      class BaseLock
        include Reflectable
        include Logging

        def self.validate_options(options = {}) = Validator.validate(options)

        def initialize(item, callback, redis_pool = nil)
          @item = item
          @callback = callback
          @redis_pool = redis_pool
          @attempt = 0
          Job.prepare(item) unless item.key?(LOCK_DIGEST)
          @lock_config = LockConfig.new(item)
        end

        def lock = raise(NotImplementedError, "#lock needs to be implemented in #{self.class}")
        def execute = raise(NotImplementedError, "#execute needs to be implemented in #{self.class}")
        def locksmith = @locksmith ||= Locksmith.new(item, @redis_pool)
        def locked?(...) = locksmith.locked?(...)

        private

        attr_reader :item, :lock_config, :callback, :attempt

        # Takes the lock or applies the conflict strategy, which `:replace` may
        # follow with one more try; the block (the rest of the client chain) runs
        # only on a lock this call holds.
        def client_lock(origin: :client)
          unless (token = locksmith.lock)
            reflect(:lock_failed, item)
            call_strategy(origin: origin) { yield if block_given? }
            return
          end
          yield if block_given?
          token
        end

        def call_strategy(origin:)
          new_job_id = nil
          strategy = strategy_for(origin)
          @attempt += 1
          strategy.call { new_job_id = lock if strategy.replace? && @attempt < 2 }
          yield if new_job_id && block_given?
        end

        def unlock_and_callback
          return callback_safely if locksmith.unlock

          reflect(:unlock_failed, item)
        end

        def callback_safely
          callback&.call
          item[JID]
        rescue StandardError => e
          reflect(:after_unlock_callback_failed, item, e)
          log_warn("After unlock callback failed: #{e.class} - #{e.message}")
          item[JID]
        end

        def strategy_for(origin)
          case origin
          when :client then @client_strategy ||= OnConflict.find_strategy(lock_config.on_client_conflict).new(item)
          when :server then @server_strategy ||= server_strategy
          else raise InvalidArgument, '#origin needs to be either `:server` or `:client`'
          end
        end

        def server_strategy = OnConflict.find_strategy(lock_config.on_server_conflict).new(item)
      end

      # Held from push until `perform` returns; kept across retries.
      class UntilExecuted < BaseLock
        def lock(&) = client_lock(&)

        def execute
          executed = locksmith.execute do
            yield
            item[JID]
          end
          executed ? unlock_and_callback : reflect(:execution_failed, item)
          nil
        rescue StandardError => e
          reflect(:execution_failed, item, e)
          raise
        end
      end

      # Held from push until `perform` starts; taken back if `perform` raises.
      class UntilExecuting < BaseLock
        def lock(&) = client_lock(&)

        def execute
          callback_safely if locksmith.unlock
          yield
        rescue StandardError => e
          reflect(:execution_failed, item, e)
          locksmith.lock(wait: 0)
          raise
        end
      end

      # Held from push until its TTL runs out; `perform` releases nothing.
      class UntilExpired < UntilExecuted
        def execute
          executed = locksmith.execute do
            yield
            item[JID]
          end
          reflect(:execution_failed, item) unless executed
        end
      end

      # No push-time lock: held only while `perform` runs, under `<digest>:RUN`.
      # A job that cannot get it within `lock_timeout` goes to the conflict strategy.
      class WhileExecuting < BaseLock
        def initialize(item, callback, redis_pool = nil)
          super
          digest = item[LOCK_DIGEST]
          item[LOCK_DIGEST] = "#{digest}#{RUN_SUFFIX}" unless digest.end_with?(RUN_SUFFIX)
        end

        def lock
          yield if block_given?
          item[JID]
        end

        def execute(&)
          executed = locksmith.execute { perform_and_unlock(&) }
          return if executed

          reflect(:execution_failed, item)
          call_strategy(origin: :server, &)
        end

        private

        # A run cut short by a shutdown keeps its lock, as one that crashed does:
        # the job is put back and re-enters it by jid. Released, it would go to
        # whoever waits, and the job would come back to a conflict, which drops,
        # buries or re-pushes it. The gem releases it.
        def perform_and_unlock
          interrupted = false
          yield
          item[JID]
        rescue Wurk::Shutdown
          interrupted = true
          raise
        ensure
          unlock_and_callback unless interrupted
        end
      end

      # WhileExecuting whose conflicts always go to the dead set.
      class WhileExecutingReject < WhileExecuting
        private

        def server_strategy = OnConflict::Reject.new(item)
      end

      # UntilExecuting at push, then WhileExecuting around `perform`.
      class UntilAndWhileExecuting < BaseLock
        def lock(origin: :client, &) = client_lock(origin: origin, &)

        # A job that holds its runtime lock has started before and was cut short. Its
        # push lock went then, to a successor for all we know, and no longer says
        # whether it may run.
        def execute
          if locksmith.unlock || runtime_lock.locked?
            runtime_lock.execute { return yield }
          else
            reflect(:unlock_failed, item)
          end
        rescue StandardError
          reflect(:execution_failed, item)
          locksmith.lock(wait: 0)
          raise
        end

        private

        def runtime_lock = @runtime_lock ||= WhileExecuting.new(item.dup, callback, @redis_pool)
      end

      # The option checks `have_valid_sidekiq_options` and `validate_worker` run.
      class Validator
        DEPRECATED_KEYS = {
          UNIQUE.to_sym => LOCK.to_sym,
          UNIQUE_ARGS.to_sym => LOCK_ARGS_METHOD.to_sym,
          LOCK_ARGS.to_sym => LOCK_ARGS_METHOD.to_sym,
          UNIQUE_PREFIX.to_sym => LOCK_PREFIX.to_sym
        }.freeze

        def self.validate(options) = new(options).validate

        attr_reader :lock_config

        def initialize(options)
          @options = options.transform_keys(&:to_sym)
          @lock_config = LockConfig.new(options)
          DEPRECATED_KEYS.each do |old, new|
            next unless @options.key?(old)

            lock_config.errors[old] = "is deprecated, use `#{new}: #{@options[old]}` instead."
          end
        end

        def validate
          ClientValidator.validate(lock_config) unless lock_config.type == :while_executing
          ServerValidator.validate(lock_config) unless lock_config.type == :until_executing
          lock_config
        end
      end

      module ClientValidator
        INVALID_ON_CONFLICTS = %i[raise reject reschedule].freeze

        def self.validate(lock_config)
          on_conflict = lock_config.on_client_conflict
          return lock_config unless INVALID_ON_CONFLICTS.include?(on_conflict)

          lock_config.errors[:on_client_conflict] = "#{on_conflict} is incompatible with the client process"
          lock_config
        end
      end

      module ServerValidator
        INVALID_ON_CONFLICTS = %i[replace].freeze

        def self.validate(lock_config)
          on_conflict = lock_config.on_server_conflict
          return lock_config unless INVALID_ON_CONFLICTS.include?(on_conflict)

          lock_config.errors[:on_server_conflict] = "#{on_conflict} is incompatible with the server process"
          lock_config
        end
      end
    end

    # The registered lock types by name, aliases included, as the gem's Config::LOCKS.
    module Locks
      ALL = {
        around_perform: Lock::WhileExecuting, while_busy: Lock::WhileExecuting,
        while_executing: Lock::WhileExecuting, while_working: Lock::WhileExecuting,
        while_executing_reject: Lock::WhileExecutingReject,
        until_executing: Lock::UntilExecuting, while_enqueued: Lock::UntilExecuting,
        until_expired: Lock::UntilExpired,
        until_completed: Lock::UntilExecuted, until_executed: Lock::UntilExecuted,
        until_performed: Lock::UntilExecuted, until_processed: Lock::UntilExecuted,
        until_and_while_executing: Lock::UntilAndWhileExecuting,
        until_successfully_completed: Lock::UntilExecuted
      }.freeze
    end
  end
end
