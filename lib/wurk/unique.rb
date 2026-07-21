# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'middleware'
require_relative 'lua'

module Wurk
  # Sidekiq Enterprise unique jobs. Best-effort dedup at enqueue time keyed
  # by a SHA256 digest of `[class, queue, args]` (overridable via
  # `sidekiq_unique_context`; ActiveJob-wrapped payloads narrow to the wrapped
  # class + its arguments — see `active_job_context`). Three lock-release
  # strategies:
  #
  #   * `unique_until: :success` (default) — lock retained through retries;
  #     server middleware DELs it on successful perform. Surviving across
  #     a process crash is bounded by `unique_for` TTL.
  #   * `unique_until: :start` — server middleware DELs the lock right
  #     *before* invoking perform; a duplicate can be enqueued while the
  #     first is running.
  #
  # A job that dies *automatically* (retries exhausted / discarded) releases
  # its lock via a death handler; manual UI kills keep the lock until TTL
  # expiry (Ent wiki, Ent-Unique-Jobs).
  #
  # Wire-compat (§3.9): single-key Redis layout — `unique:<sha256>` STRING
  # holding the owning JID. Scheduled jobs extend the TTL by the delay so
  # the lock covers the entire wait+execution window (§3.4).
  #
  # This is the native replacement for the `sidekiq-unique-jobs` gem; see the
  # migration guide for the `lock:` → `unique_until:` translation table.
  #
  # @example Enable globally, then declare per worker
  #   Sidekiq::Enterprise.unique!   # activate the middleware once, at boot
  #
  #   class ChargeJob
  #     include Sidekiq::Job
  #     sidekiq_options unique_for: 10.minutes, unique_until: :success
  #
  #     # optional: customize the dedup key
  #     def self.sidekiq_unique_context(job)
  #       job["args"].first   # dedup on the first arg only
  #     end
  #   end
  #
  # Spec: docs/target/sidekiq-ent.md §3.
  module Unique
    KEY_PREFIX = 'unique:'
    DEFAULT_UNTIL = :success
    VALID_UNTIL = %i[success start].freeze

    # Class names that carry an ActiveJob payload as their single arg. The
    # canonical one Wurk writes is `Sidekiq::ActiveJob::Wrapper`; the others
    # appear in payloads enqueued by older Sidekiq/Rails versions still sitting
    # in Redis at gem-swap time.
    ACTIVE_JOB_WRAPPERS = [
      'Sidekiq::ActiveJob::Wrapper',
      'Wurk::ActiveJob::Wrapper',
      'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper',
      'ActiveJob::QueueAdapters::WurkAdapter::JobWrapper'
    ].freeze

    # Raised at enqueue when a worker opts into both `unique_for:` and
    # `encrypt: true` (§3.8: mutually exclusive).
    class ConfigurationError < StandardError; end

    # Ent parity: a job that dies automatically releases its lock so a
    # duplicate can enqueue immediately. Manual API/UI kills keep the lock
    # until TTL expiry (Ent wiki, Ent-Unique-Jobs) — they reach death
    # handlers too (Sidekiq fires them on API kills), so we recognize the
    # synthesized kill exception and skip the release for it. Atomic
    # CAS-DEL via the shared Lua script mirrors ServerMiddleware#release.
    DEATH_HANDLER = lambda do |job, exception|
      next unless Wurk::Unique.enabled?
      next unless Wurk::Unique.coerce_ttl(job['unique_for'])
      next if exception.instance_of?(::RuntimeError) && exception.message == DeadSet::API_KILL_MESSAGE

      Wurk.redis { |conn| Wurk::Unique.release_if_owner(conn, Wurk::Unique.lock_key_for(job), job['jid']) }
    end

    # Atomic compare-and-delete of a unique lock key. Two-command
    # GET-then-DEL is not a real CAS — the key can expire between the GET
    # and DEL, letting a fresh enqueue grab it, and the bare DEL would
    # then drop the new owner's lock. Routed through a single Lua script
    # (`Wurk::Lua::RELEASE_IF_OWNER`) shared by `ServerMiddleware#release`
    # (normal success/start release) and `DEATH_HANDLER` (automatic-death
    # release) so the two paths cannot drift.
    def self.release_if_owner(conn, key, jid)
      Wurk::Lua::Loader.eval_cached(conn, :release_if_owner, keys: [key], argv: [jid])
    end

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

      # Compute the lock key for an arbitrary `(queue, klass, args)` triple,
      # bypassing `sidekiq_unique_context`. Public so operators can compute
      # the key of a worker that uses the default context (docs §8).
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
      # value (e.g. a subset of args). Spec §3.5. ActiveJob-wrapped payloads
      # get a narrowed default (see `active_job_context`) because their raw
      # args can never repeat.
      def unique_context(job)
        klass = resolve_class(job['class'])
        return klass.sidekiq_unique_context(job) if klass.respond_to?(:sidekiq_unique_context)

        active_job_context(job) || [job['class'], job['queue'], job['args']]
      end

      private

      # An ActiveJob payload's args are `[job.serialize]`, and that hash
      # carries a fresh `job_id` plus an `enqueued_at` timestamp on every
      # push — digesting it verbatim produces a new key every time, so
      # nothing is ever deduped. Identity is therefore narrowed to the two
      # fields that describe *which* job this is:
      #
      #   * `job_class`  — the real worker; the wire `class` is only the wrapper.
      #   * `arguments`  — the serialized perform args.
      #
      # Everything else in the serialized hash is per-push state, not
      # identity: `job_id`/`provider_job_id` (fresh per push), `enqueued_at`
      # and `scheduled_at` (timestamps), `executions`/`exception_executions`
      # (retry counters, so a retry re-push would otherwise miss its own
      # lock), `priority`, `locale` and `timezone` (ambient request state —
      # the same logical job enqueued from a different locale is still the
      # same job). `queue_name` is dropped as redundant: the wire-level
      # `job["queue"]` it was copied into is already in the context, keeping
      # the "queue is part of the key" rule identical to the plain path.
      #
      # The wrapper class name stays in the context so an ActiveJob and a
      # plain worker of the same name and args can't collide on one lock.
      def active_job_context(job)
        return nil unless ACTIVE_JOB_WRAPPERS.include?(job['class'].to_s)

        data = job['args']
        data = data.first if data.is_a?(::Array) && data.size == 1
        return nil unless data.is_a?(::Hash) && data.key?('job_class') && data.key?('arguments')

        [job['class'], job['queue'], data['job_class'], data['arguments']]
      end

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
        handlers = Wurk.configuration.death_handlers
        handlers << DEATH_HANDLER unless handlers.include?(DEATH_HANDLER)
      end
    end

    # Coerce `unique_for` to a numeric seconds value. Accepts Integer,
    # Numeric, ActiveSupport::Duration (any `to_i`-respondent), or `false`
    # (skip). Returns nil when uniqueness should be skipped.
    def self.coerce_ttl(value)
      return nil if value.nil? || value == false
      # `.to_i`, not `value`: ActiveSupport::Duration overrides `is_a?(Integer)`
      # to return true (it delegates to its underlying value), so `1.hour` passes
      # this guard — returning the raw Duration handed redis-client a non-Integer
      # EX arg and raised TypeError at enqueue (#253).
      return value.to_i if value.is_a?(Integer) && value.positive?
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
      # Routed through lock_key_for, not lock_key: the probe must honor
      # `sidekiq_unique_context` (and the ActiveJob default) or it reports
      # "free" for every worker that customizes its digest.
      key = lock_key_for('class' => klass.to_s, 'queue' => queue.to_s, 'args' => payload)
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

        reject_encrypted!(job)
        acquire_or_drop(redis_pool, job, Wurk::Unique.lock_key_for(job), ttl, &)
      end

      private

      # §3.8: unique + encryption are mutually exclusive. Both features append
      # to the same client chain, so whether the digest sees plaintext args or
      # a random-IV envelope depended purely on which initializer ran first —
      # and in the envelope case uniqueness silently never matched again.
      # Failing the push is the only outcome that is identical in both
      # orderings and impossible to miss. The check is per job, so the two
      # features still coexist fine on *different* workers.
      def reject_encrypted!(job)
        return unless job['encrypt']
        return unless defined?(Wurk::Encryption) && Wurk::Encryption.enabled?

        raise Wurk::Unique::ConfigurationError,
              "#{job['class']} sets both `unique_for` and `encrypt: true`, which cannot work: " \
              'encryption rewrites the last argument with a fresh IV on every push, so the ' \
              'unique digest never repeats. Drop one of the two options on this worker.'
      end

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

          holder = conn.call('GET', key)
          # The job's own jid holding the lock is a re-push, not a duplicate:
          # scheduled/retry promotion re-runs this chain while the
          # enqueue-time lock is still live (§3.4/§3.7) — dropping here would
          # silently lose the job.
          return yield if holder == job['jid']
          # nil holder: the lock expired between the failed SET NX and the
          # GET — re-acquire instead of dropping.
          return yield if holder.nil? && conn.call('SET', key, job['jid'], 'NX', 'EX', ttl) == 'OK'

          log_duplicate(job, holder)
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

      # Atomic CAS-DEL: only drop the key if the owning JID still matches
      # ours. Prevents a long-overdue retry from releasing a fresh lock
      # held by a re-enqueued duplicate after the original TTL expired.
      # Shares the Lua script with `DEATH_HANDLER` so both release paths
      # have identical semantics.
      def release(key, jid)
        redis_pool.with { |conn| Wurk::Unique.release_if_owner(conn, key, jid) }
      rescue StandardError => e
        Wurk.logger&.warn { "Wurk::Unique release failed: #{e.class}: #{e.message}" }
      end
    end
  end
end
