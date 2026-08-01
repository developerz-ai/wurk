# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require_relative 'lua'
require_relative 'pool_checkout'

module Wurk
  # Sidekiq Enterprise rate limiters: concurrent, bucket, window, leaky,
  # points, unlimited. Lua-backed; all timing inside Lua is from TIME so
  # clock skew across hosts doesn't matter inside one Redis. Spec:
  # docs/target/sidekiq-ent.md §1.
  #
  # @example Throttle to 50 concurrent uses, waiting up to the default timeout
  #   STRIPE = Sidekiq::Limiter.concurrent("stripe", 50)
  #
  #   class ChargeJob
  #     include Sidekiq::Job
  #     def perform(id)
  #       STRIPE.within_limit { Stripe::Charge.create(...) }
  #     end
  #   end
  #
  # Layout (one file per type under `lib/wurk/limiter/`):
  #   * `Limiter::Base` owns the metadata write (lmtr:{name}) + the global
  #     `lmtr-list` registration so the Web UI can list every limiter, and
  #     the uniform `status` shape.
  #   * Per-type subclasses (Concurrent / Bucket / Window / Leaky / Points)
  #     own their acquire/wait loop. Each delegates the atomic step to a
  #     Lua script in `lib/wurk/lua/limiter_*.lua`.
  #   * `Unlimited` is a no-op stub for tests and the `unlimited(*)`
  #     constructor — same `within_limit` surface, never raises.
  #   * `ServerMiddleware` catches OverLimit, reschedules, and applies the
  #     poison brake.
  #
  # Wire-compat: every key uses the `lmtr-...:` prefix family from §1.7
  # and the limiter is added to the shared `lmtr-list` SET.
  module Limiter
    DEFAULT_TTL = 90 * 24 * 3600
    DEFAULT_WAIT_TIMEOUT = 5
    DEFAULT_LOCK_TIMEOUT = 30
    DEFAULT_RESCHEDULE = 20
    DEFAULT_BACKOFF = lambda do |_limiter, job, _exc|
      overrated = job.is_a?(Hash) ? job.fetch('overrated', 0).to_i : 0
      (300 * overrated) + rand(300) + 1
    end

    NAME_PATTERN = /\A[\w\-:.\#@]+\z/

    LIST_KEY = 'lmtr-list'

    # Server middleware catches OverLimit, increments `job['overrated']`, and
    # reschedules onto the same queue with `Time.now + backoff`. The
    # `#limiter` attr lets the middleware reach the per-limiter backoff
    # proc + reschedule cap. `#job` is set by the middleware just before the
    # re-raise so error_handlers can see which job was in flight.
    class OverLimit < StandardError
      attr_reader :limiter
      attr_accessor :job

      def initialize(limiter, job = nil, msg = nil)
        @limiter = limiter
        @job = job
        super(msg || "limit '#{limiter.name}' (#{limiter.type}) reached")
      end
    end

    # Global config. Sidekiq Enterprise documents three knobs (§1.6):
    # `backoff` (Proc), `redis` (a Hash that builds a dedicated pool), and
    # `errors` (Array of exception classes the middleware also treats as
    # OverLimit). All three are mutable and re-read on every push/perform.
    class Config
      attr_accessor :backoff, :errors
      attr_reader :redis

      def initialize
        @backoff = DEFAULT_BACKOFF
        @errors = [OverLimit]
        @redis = nil
        @pool = nil
      end

      # Accept either a Hash (the documented Sidekiq Ent shape — `{ size:,
      # url: }`) or an already-built `RedisPool`. The first redis read
      # lazily materializes the pool; per-fork safety is the caller's
      # responsibility (same contract as Wurk.redis_pool).
      def redis=(value)
        @redis = value
        # Reset the memo `pool` actually reads — resetting a different ivar
        # left the old pool pinned after `config.redis = {...}`.
        @pool = nil
      end

      def pool
        return nil if @redis.nil?

        @pool ||= case @redis
                  when Wurk::RedisPool then @redis
                  when Hash
                    Wurk::RedisPool.new(
                      size: @redis[:size] || 10,
                      name: 'limiter',
                      **@redis.except(:size, :name)
                    )
                  else
                    raise ArgumentError, "Limiter.config.redis must be Hash or RedisPool, got #{@redis.class}"
                  end
      end
    end

    # `:second :minute :hour :day` symbols → seconds. Window also accepts
    # a raw Integer; bucket does not (boundary semantics require a unit).
    INTERVAL_UNITS = {
      second: 1,
      minute: 60,
      hour: 3600,
      day: 86_400
    }.freeze

    # Type string (as stored in the `lmtr:{name}` meta hash) → subclass.
    # Drives `build` for dashboard introspection.
    TYPE_CLASSES = {
      'concurrent' => 'Concurrent',
      'bucket' => 'Bucket',
      'window' => 'Window',
      'leaky' => 'Leaky',
      'points' => 'Points'
    }.freeze

    class << self
      def configure
        yield config
      end

      def config
        @config ||= Config.new
      end

      # Test helper: blow away config + cached pool so a test that mutates
      # `config.backoff` doesn't leak into the next one. Not part of the
      # public Sidekiq surface.
      def reset_config!
        @config = nil
      end

      # Redis access: caller-supplied pool (Limiter.configure.redis = …) wins,
      # else fall back to the default Wurk pool. This is the same hierarchy
      # Sidekiq Ent documents — dedicated rate-limiter pool is opt-in.
      def redis(idempotent: false, &)
        PoolCheckout.with(config.pool || Wurk.redis_pool, idempotent, &)
      end

      # `ZRANGE key 0 0 WITHSCORES` yields a single [member, score] pair, but the
      # shape depends on the protocol: RESP3 (redis-client's default vs Redis >= 7)
      # nests it as [[member, score]]; RESP2 returns a flat [member, score].
      # Return the score as a Float across both, or nil when the set is empty.
      # (The old flat-only `row[1]` silently collapsed to 0.0 under RESP3.)
      def first_score(row)
        pair = row.first
        return nil if pair.nil?

        (pair.is_a?(Array) ? pair.last : row[1]).to_f
      end

      def concurrent(name, limit, wait_timeout: DEFAULT_WAIT_TIMEOUT, lock_timeout: DEFAULT_LOCK_TIMEOUT,
                     policy: :raise, backoff: nil, ttl: DEFAULT_TTL)
        Concurrent.new(name,
                       limit: limit,
                       wait_timeout: wait_timeout,
                       lock_timeout: lock_timeout,
                       policy: policy,
                       backoff: backoff,
                       ttl: ttl)
      end

      def bucket(name, count, interval, wait_timeout: DEFAULT_WAIT_TIMEOUT, backoff: nil,
                 ttl: DEFAULT_TTL, reschedule: DEFAULT_RESCHEDULE)
        Bucket.new(name,
                   count: count,
                   interval: interval,
                   wait_timeout: wait_timeout,
                   backoff: backoff,
                   ttl: ttl,
                   reschedule: reschedule)
      end

      def window(name, count, interval, wait_timeout: DEFAULT_WAIT_TIMEOUT, backoff: nil,
                 ttl: DEFAULT_TTL, reschedule: DEFAULT_RESCHEDULE)
        Window.new(name,
                   count: count,
                   interval: interval,
                   wait_timeout: wait_timeout,
                   backoff: backoff,
                   ttl: ttl,
                   reschedule: reschedule)
      end

      def leaky(name, bucket_size, drain, wait_timeout: DEFAULT_WAIT_TIMEOUT, backoff: nil, ttl: DEFAULT_TTL)
        Leaky.new(name,
                  bucket_size: bucket_size,
                  drain: drain,
                  wait_timeout: wait_timeout,
                  backoff: backoff,
                  ttl: ttl)
      end

      def points(name, initial_points, refill_per_second, backoff: nil, ttl: DEFAULT_TTL)
        Points.new(name,
                   initial: initial_points,
                   refill: refill_per_second,
                   backoff: backoff,
                   ttl: ttl)
      end

      def unlimited(*_args, **_opts)
        Unlimited.new
      end

      # Reconstruct a limiter from its persisted metadata for read-only
      # introspection (the dashboard `status` column). `register: false`
      # keeps the GET side-effect-free. Returns nil for an unknown type.
      def build(name, type, options, register: false)
        return Unlimited.new if type.to_s == 'unlimited'

        klass_name = TYPE_CLASSES[type.to_s]
        return nil unless klass_name

        const_get(klass_name).new(name, register: register, **coerce_build_options(options))
      end

      def interval_seconds(interval, allow_integer:)
        interval = interval.to_sym if interval.is_a?(String) && INTERVAL_UNITS.key?(interval.to_sym)
        case interval
        when Symbol
          INTERVAL_UNITS.fetch(interval) do
            raise ArgumentError, "interval must be one of #{INTERVAL_UNITS.keys.inspect} (got #{interval.inspect})"
          end
        when Integer
          unless allow_integer
            raise ArgumentError, "interval must be a Symbol (got Integer); use #{INTERVAL_UNITS.keys.inspect}"
          end

          interval
        else
          raise ArgumentError, "interval must be Symbol or Integer (got #{interval.class})"
        end
      end

      private

      # Stored options round-trip through JSON, so symbol keys arrive as
      # strings and unit symbols (`:minute`) as `"minute"`. Restore both so a
      # rebuilt limiter validates the same as a freshly-constructed one.
      def coerce_build_options(options)
        opts = options.transform_keys(&:to_sym)
        %i[interval drain].each do |k|
          v = opts[k]
          opts[k] = v.to_sym if v.is_a?(String) && INTERVAL_UNITS.key?(v.to_sym)
        end
        opts
      end
    end
  end
end

require_relative 'limiter/base'
require_relative 'limiter/concurrent'
require_relative 'limiter/bucket'
require_relative 'limiter/window'
require_relative 'limiter/leaky'
require_relative 'limiter/points'
require_relative 'limiter/unlimited'
require_relative 'middleware'
require_relative 'limiter/server_middleware'
# Server-middleware registration happens in wurk.rb after the Wurk
# `class << self` block defines `Wurk.configuration` — limiter.rb
# loads earlier than that, so trying to call it here would NoMethodError.
