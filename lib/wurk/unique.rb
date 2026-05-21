# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'middleware'

module Wurk
  # Sidekiq Enterprise unique jobs. Best-effort dedup at enqueue time keyed
  # by a SHA256 digest of `[class, queue, args]` (overridable via
  # `sidekiq_unique_context`). Three lock-release strategies:
  #
  #   * `unique_until: :success` (default) — lock retained through retries;
  #     server middleware DELs it on successful perform. Surviving across
  #     a process crash is bounded by `unique_for` TTL.
  #   * `unique_until: :start` — server middleware DELs the lock right
  #     *before* invoking perform; a duplicate can be enqueued while the
  #     first is running.
  #
  # Wire-compat (§3.9): single-key Redis layout — `unique:<sha256>` STRING
  # holding the owning JID. Scheduled jobs extend the TTL by the delay so
  # the lock covers the entire wait+execution window (§3.4).
  #
  # Spec: docs/target/sidekiq-ent.md §3.
  module Unique
    KEY_PREFIX = 'unique:'
    DEFAULT_UNTIL = :success
    VALID_UNTIL = %i[success start].freeze

    # `Sidekiq::Enterprise.unique!` flips this on. The middleware pair is
    # always loaded (so worker `sidekiq_options unique_for:` is a no-op
    # without `unique!`) — only when the flag is set does the client
    # middleware actually compute and SETNX the digest.
    class << self
      def enabled?
        @enabled == true
      end

      def enable! # rubocop:disable Naming/PredicateMethod
        @enabled = true
        register_middleware!
        true
      end

      # Test helper — not part of the public Sidekiq surface. Clears the
      # flag so per-test enable!/disable! does not leak across runs.
      def disable!
        @enabled = false
        nil
      end

      # Compute the lock key for an arbitrary `(queue, klass, args)` triple.
      # Used by both the client middleware and the public `locked?` probe so
      # they cannot drift.
      def lock_key(klass, queue, args)
        context = [klass.to_s, queue.to_s, args]
        "#{KEY_PREFIX}#{Digest::SHA256.hexdigest(JSON.dump(context))}"
      end

      # Compute the lock key from a job payload, honoring
      # `sidekiq_unique_context` when the worker class is loaded and
      # defines it.
      def lock_key_for(job)
        context = unique_context(job)
        "#{KEY_PREFIX}#{Digest::SHA256.hexdigest(JSON.dump(context))}"
      end

      # Default: `[class, queue, args]`. Workers may override by defining
      # `self.sidekiq_unique_context(job)` returning any JSON-serializable
      # value (e.g. a subset of args). Spec §3.5.
      def unique_context(job)
        klass = resolve_class(job['class'])
        if klass.respond_to?(:sidekiq_unique_context)
          klass.sidekiq_unique_context(job)
        else
          [job['class'], job['queue'], job['args']]
        end
      end

      private

      def resolve_class(name)
        return nil if name.nil? || name.to_s.empty?

        ::Object.const_get(name.to_s)
      rescue ::NameError
        nil
      end

      def register_middleware!
        Wurk.configuration.client_middleware.add(ClientMiddleware) \
          unless Wurk.configuration.client_middleware.exists?(ClientMiddleware)
        Wurk.configuration.server_middleware.add(ServerMiddleware) \
          unless Wurk.configuration.server_middleware.exists?(ServerMiddleware)
      end
    end

    # Coerce `unique_for` to a numeric seconds value. Accepts Integer,
    # Numeric, ActiveSupport::Duration (any `to_i`-respondent), or `false`
    # (skip). Returns nil when uniqueness should be skipped.
    def self.coerce_ttl(value)
      return nil if value.nil? || value == false
      return value if value.is_a?(Integer) && value.positive?
      return value.to_i if value.is_a?(Numeric)
      return value.to_i if duration_like?(value)

      nil
    end

    def self.duration_like?(value)
      return false unless value.respond_to?(:to_i)

      value.respond_to?(:since) || value.class.name.to_s.include?('Duration')
    end

    # ------------------------------------------------------------------
    # Introspection — `Sidekiq::Enterprise::Unique.locked?`
    # ------------------------------------------------------------------

    # @return [String, nil] owning jid, or nil when the lock is free.
    def self.locked?(queue_or_klass, klass_or_args = nil, args = nil)
      queue, klass, payload = normalize_locked_args(queue_or_klass, klass_or_args, args)
      key = lock_key(klass, queue, payload)
      Wurk.redis { |c| c.call('GET', key) }
    end

    # Accepts either `(klass, args)` or `(queue, klass, args)`. Without a
    # queue the default Wurk job queue is assumed — matches the Sidekiq
    # Ent docs §3.6.
    def self.normalize_locked_args(first, second, third)
      if third.nil?
        [Wurk.default_job_options['queue'] || 'default', first, Array(second)]
      else
        [first.to_s, second, Array(third)]
      end
    end
    private_class_method :normalize_locked_args

    # ------------------------------------------------------------------
    # Client middleware — SETNX lock at push time.
    # ------------------------------------------------------------------
    #
    # Drops the duplicate by returning nil from the chain (Wurk::Client
    # treats nil as "halted"; the caller's `perform_async` returns nil
    # JID). Logs the holder JID for debuggability.
    class ClientMiddleware
      include Wurk::Middleware::ClientMiddleware

      def call(_worker, job, _queue, redis_pool, &)
        return yield unless Wurk::Unique.enabled?

        ttl = effective_ttl(job)
        return yield if ttl.nil?

        acquire_or_drop(redis_pool, job, Wurk::Unique.lock_key_for(job), ttl, &)
      end

      private

      # Add `at - now` delay to the base TTL so a scheduled job's lock
      # spans the wait + execution window (§3.4). Returns nil when the
      # job opts out (`unique_for: false` / missing).
      def effective_ttl(job)
        base = Wurk::Unique.coerce_ttl(job['unique_for'])
        return nil if base.nil?
        return base unless job['at']

        delay = (job['at'].to_f - ::Time.now.to_f).ceil
        delay.positive? ? base + delay : base
      end

      def acquire_or_drop(pool, job, key, ttl)
        pool.with do |conn|
          return yield if conn.call('SET', key, job['jid'], 'NX', 'EX', ttl) == 'OK'

          log_duplicate(job, conn.call('GET', key))
        end
        nil
      end

      def log_duplicate(job, holder)
        return unless Wurk.logger

        msg = "Wurk::Unique: duplicate #{job['class']} dropped " \
              "(jid=#{job['jid']} blocked by jid=#{holder || '?'})"
        Wurk.logger.info { msg }
      end
    end

    # ------------------------------------------------------------------
    # Server middleware — release lock per `unique_until` strategy.
    # ------------------------------------------------------------------
    #
    # `:start`   → DEL before perform. Lock-after-this-point not held; a
    #              duplicate can be re-enqueued while the first runs.
    # `:success` → DEL only on successful return. Retries keep the lock.
    #              Spec §3.7: a raise during perform leaves the lock so
    #              the retry can proceed; the TTL bounds the worst case.
    class ServerMiddleware
      include Wurk::Middleware::ServerMiddleware

      def call(_worker, job, _queue)
        return yield unless Wurk::Unique.enabled? && Wurk::Unique.coerce_ttl(job['unique_for'])

        mode = unique_until(job)
        key = Wurk::Unique.lock_key_for(job)

        if mode == :start
          release(key, job['jid'])
          yield
        else
          result = yield
          release(key, job['jid'])
          result
        end
      end

      private

      # Honor `unique_until: :start | :success`, fall back to default.
      def unique_until(job)
        raw = job['unique_until']
        return DEFAULT_UNTIL if raw.nil?

        sym = raw.to_sym
        VALID_UNTIL.include?(sym) ? sym : DEFAULT_UNTIL
      end

      # CAS DEL: only drop the key if the owning JID still matches ours.
      # Prevents a long-overdue retry from releasing a fresh lock held by
      # a re-enqueued duplicate after the original TTL expired.
      def release(key, jid)
        redis_pool.with do |conn|
          conn.call('DEL', key) if conn.call('GET', key) == jid
        end
      rescue StandardError => e
        Wurk.logger&.warn { "Wurk::Unique release failed: #{e.class}: #{e.message}" }
      end
    end
  end
end
