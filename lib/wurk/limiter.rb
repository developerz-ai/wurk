# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'
require_relative 'lua'

module Wurk
  # Sidekiq Enterprise rate limiters: concurrent, bucket, window, leaky,
  # points, unlimited. Lua-backed; all timing inside Lua is from TIME so
  # clock skew across hosts doesn't matter inside one Redis. Spec:
  # docs/target/sidekiq-ent.md §1.
  #
  # Layout:
  #   * `Limiter::Base` owns the metadata write (lmtr:{name}) + the global
  #     `lmtr-list` registration so the Web UI can list every limiter.
  #   * Per-type subclasses (Concurrent / Bucket / Window / Leaky / Points)
  #     own their acquire/wait loop. Each delegates the atomic step to a
  #     Lua script in `lib/wurk/lua/limiter_*.lua`.
  #   * `Unlimited` is a no-op stub for tests and the `unlimited(*)`
  #     constructor — same `within_limit` surface, never raises.
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
        @redis_pool = nil
      end

      # Accept either a Hash (the documented Sidekiq Ent shape — `{ size:,
      # url: }`) or an already-built `RedisPool`. The first redis read
      # lazily materializes the pool; per-fork safety is the caller's
      # responsibility (same contract as Wurk.redis_pool).
      def redis=(value)
        @redis = value
        @redis_pool = nil
      end

      def pool
        return nil if @redis.nil?

        @redis_pool ||= case @redis
                        when Wurk::RedisPool then @redis
                        when Hash
                          Wurk::RedisPool.new(
                            size: @redis[:size] || 10,
                            url: @redis[:url] || Wurk::RedisPool::DEFAULT_URL,
                            timeout: @redis[:timeout] || Wurk::RedisPool::DEFAULT_TIMEOUT,
                            name: 'limiter'
                          )
                        else
                          raise ArgumentError, "Limiter.config.redis must be Hash or RedisPool, got #{@redis.class}"
                        end
      end
    end

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
      def redis(&)
        pool = config.pool || Wurk.redis_pool
        pool.with(&)
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

      # `:second :minute :hour :day` symbols → seconds. Window also accepts
      # a raw Integer; bucket does not (boundary semantics require a unit).
      INTERVAL_UNITS = {
        second: 1,
        minute: 60,
        hour: 3600,
        day: 86_400
      }.freeze

      def interval_seconds(interval, allow_integer:)
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
    end

    # Base class. Holds the public introspection contract documented in
    # §1.5 — name / type / options / size / status / reset / delete plus
    # the `within_limit(...) { ... }` block. Subclasses override the
    # acquire path and the per-type metric/size methods.
    class Base
      attr_reader :name, :options

      def initialize(name, **options)
        unless name.is_a?(String) && NAME_PATTERN.match?(name)
          raise ArgumentError, "limiter name must match #{NAME_PATTERN.inspect} (got #{name.inspect})"
        end

        ttl = options[:ttl] || DEFAULT_TTL
        # Spec §1.2: ttl floor of 24h. Anything tighter risks losing the
        # metadata hash mid-job and orphaning slots that read it.
        raise ArgumentError, 'ttl must be >= 86_400' if ttl < 86_400

        @name = name.dup.freeze
        @options = options
        register!
      end

      def type
        raise NotImplementedError
      end

      def within_limit(**, &)
        raise NotImplementedError
      end

      def size
        0
      end

      def status
        {}
      end

      def reset
        Wurk::Limiter.redis do |c|
          state_keys.each { |k| c.call('DEL', k) }
        end
      end

      def delete
        Wurk::Limiter.redis do |c|
          (state_keys + [meta_key]).each { |k| c.call('DEL', k) }
          c.call('SREM', LIST_KEY, @name)
        end
      end

      # Stable fingerprint for the limiter — Sidekiq 8.0+ switched from
      # SHA1 → SHA256 (~10% larger encoding). Web UI groups limiters by
      # this so that interpolated names (`stripe-#{user_id}`) get a single
      # row per shape.
      def fingerprint
        @fingerprint ||= Digest::SHA256.hexdigest("#{type}|#{@name}|#{JSON.dump(serializable_options)}")
      end

      protected

      def meta_key
        "lmtr:#{@name}"
      end

      def state_keys
        []
      end

      def serializable_options
        @options.transform_values do |v|
          case v
          when Proc then '<proc>'
          when Symbol, Numeric, String, true, false, nil then v
          else v.to_s
          end
        end
      end

      def register!
        Wurk::Limiter.redis do |c|
          c.call('SADD', LIST_KEY, @name)
          c.call(
            'HSET', meta_key,
            'type', type.to_s,
            'options', JSON.dump(serializable_options),
            'fingerprint', fingerprint
          )
          c.call('EXPIRE', meta_key, @options[:ttl])
        end
      end

      def ttl
        @options[:ttl]
      end

      # Stable random slot id (Concurrent) / nonce (Window). 16 hex chars
      # = 8 bytes — wide enough to avoid collision under any realistic
      # burst and short enough to keep ZSET memory bounded.
      def random_id
        SecureRandom.hex(8)
      end

      def lua(name, keys:, argv:)
        Wurk::Limiter.redis do |c|
          Wurk::Lua::Loader.eval_cached(c, name, keys: keys, argv: argv)
        end
      end
    end

    # ---- Concurrent ---------------------------------------------------
    #
    # Atomic slot acquisition in a ZSET. Score = expiry epoch; the acquire
    # script first evicts expired slots (bumping the `reclaimed` metric)
    # then ZADDs if there's headroom.
    #
    # On exhaustion: spin loop with backoff. The spec says "blocks via
    # Redis stream XREAD" — that's a perf optimization; the visible
    # behavior is identical: blocks up to `wait_timeout` then OverLimit
    # (or silent return for `policy: :ignore`).
    class Concurrent < Base
      WAIT_SLEEP = 0.05

      def type = :concurrent

      def size
        Wurk::Limiter.redis { |c| c.call('ZCARD', state_key).to_i }
      end

      def status
        h = Wurk::Limiter.redis { |c| c.call('HGETALL', stats_key) }
        # redis-client returns either a flat array or a hash depending on
        # the server version — normalize once so callers always see a hash.
        h = h.each_slice(2).to_h if h.is_a?(Array)
        %w[held held_time immediate waited wait_time overages reclaimed].each_with_object({}) do |k, out|
          out[k] = (h[k] || '0').to_i
        end
      end

      def within_limit(&block)
        raise ArgumentError, 'block required' unless block

        started = monotime
        deadline = started + @options[:wait_timeout]
        slot = random_id
        acquired_at = nil
        loop do
          result = acquire(slot)
          if result[0].to_i == 1
            acquired_at = monotime
            break
          end

          return if @options[:policy] == :ignore

          remaining = deadline - monotime
          if remaining <= 0
            bump_counter('overages')
            raise OverLimit.new(self)
          end

          sleep [remaining, WAIT_SLEEP].min
        end

        begin
          incr_immediate_or_waited(acquired_at - started)
          block.call
        ensure
          release(slot)
          bump_counter('held_time', (monotime - acquired_at).to_i) if acquired_at
        end
      end

      protected

      def state_keys
        [state_key, stats_key]
      end

      private

      def state_key
        "lmtr-cs:#{@name}"
      end

      def stats_key
        "lmtr-stats:#{@name}"
      end

      def acquire(slot)
        lua(:limiter_concurrent_acquire,
            keys: [state_key, stats_key],
            argv: [@options[:limit], @options[:lock_timeout], slot, ttl])
      end

      def release(slot)
        lua(:limiter_concurrent_release, keys: [state_key], argv: [slot])
      end

      def bump_counter(field, by = 1)
        Wurk::Limiter.redis do |c|
          c.call('HINCRBY', stats_key, field, by)
          c.call('EXPIRE', stats_key, ttl)
        end
      end

      def incr_immediate_or_waited(elapsed)
        if elapsed < WAIT_SLEEP
          bump_counter('immediate')
        else
          bump_counter('waited')
          bump_counter('wait_time', elapsed.to_i)
        end
      end

      def monotime
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end

    # ---- Bucket -------------------------------------------------------
    #
    # Cardinal-boundary counter. Reset at the top of the unit (00:00 of
    # minute/hour/day). On exhaustion sleep until next boundary, retry,
    # OverLimit if that exceeds wait_timeout.
    class Bucket < Base
      def type = :bucket

      def initialize(name, **options)
        # Eager interval validation so a typo in `:fortnight` blows up at boot,
        # not at first call. Lazy validation defers failures to runtime.
        Limiter.interval_seconds(options[:interval], allow_integer: false)
        super
      end

      def size
        epoch = (::Time.now.to_i / interval_seconds) * interval_seconds
        key = "lmtr-b:#{@name}:#{epoch / interval_seconds}"
        Wurk::Limiter.redis { |c| (c.call('GET', key) || '0').to_i }
      end

      def within_limit(used: 1, &block)
        raise ArgumentError, 'block required' unless block

        deadline = ::Time.now.to_f + @options[:wait_timeout]
        loop do
          ok, _current, secs_to_next = acquire(used)
          return block.call if ok.to_i == 1

          remaining = deadline - ::Time.now.to_f
          raise OverLimit.new(self) if remaining <= 0

          sleep [remaining, secs_to_next.to_f, 0.05].compact.min.clamp(0.0, remaining)
        end
      end

      protected

      def state_keys
        # Bucket keys are per-epoch and self-expiring; reset wipes the
        # current epoch, the only one a caller could care about. Older
        # epochs already EXPIRE'd.
        epoch = ::Time.now.to_i / interval_seconds
        ["lmtr-b:#{@name}:#{epoch}"]
      end

      private

      def interval_seconds
        @interval_seconds ||= Limiter.interval_seconds(@options[:interval], allow_integer: false)
      end

      def acquire(used)
        lua(:limiter_bucket_acquire,
            keys: ["lmtr-b:#{@name}"],
            argv: [@options[:count], interval_seconds, used, ttl])
      end
    end

    # ---- Window -------------------------------------------------------
    #
    # Sliding window via ZSET of timestamps. Accepts symbolic units or a
    # raw Integer (in seconds). Used-units expand to N ZADDs in the Lua
    # script so multi-charge calls remain atomic.
    class Window < Base
      WAIT_SLEEP = 0.5

      def type = :window

      def initialize(name, **options)
        # Symbol or raw Integer (spec §1.2: window accepts both).
        Limiter.interval_seconds(options[:interval], allow_integer: true)
        super
      end

      def size
        cutoff = ::Time.now.to_f - interval_seconds
        Wurk::Limiter.redis do |c|
          c.call('ZREMRANGEBYSCORE', state_key, '-inf', "(#{cutoff}")
          c.call('ZCARD', state_key).to_i
        end
      end

      def within_limit(used: 1, &block)
        raise ArgumentError, 'block required' unless block

        deadline = ::Time.now.to_f + @options[:wait_timeout]
        loop do
          ok, _current, _oldest = acquire(used)
          return block.call if ok.to_i == 1

          remaining = deadline - ::Time.now.to_f
          raise OverLimit.new(self) if remaining <= 0

          sleep [remaining, WAIT_SLEEP].min
        end
      end

      protected

      def state_keys
        [state_key]
      end

      private

      def state_key
        "lmtr-w:#{@name}"
      end

      def interval_seconds
        @interval_seconds ||= Limiter.interval_seconds(@options[:interval], allow_integer: true)
      end

      def acquire(used)
        lua(:limiter_window_acquire,
            keys: [state_key],
            argv: [@options[:count], interval_seconds, used, ttl, random_id])
      end
    end

    # ---- Leaky --------------------------------------------------------
    #
    # Leaky bucket: drain rate = bucket_size / drain ops/sec. Stored as a
    # HASH of {level, last} — Lua compares level vs bucket_size after
    # leaking elapsed * drain_per_sec.
    class Leaky < Base
      WAIT_SLEEP = 0.05

      def type = :leaky

      def size
        h = Wurk::Limiter.redis { |c| c.call('HGET', state_key, 'level') }
        h.to_f
      end

      def within_limit(&block)
        raise ArgumentError, 'block required' unless block

        deadline = ::Time.now.to_f + @options[:wait_timeout]
        loop do
          ok, _level = acquire
          return block.call if ok.to_i == 1

          remaining = deadline - ::Time.now.to_f
          raise OverLimit.new(self) if remaining <= 0

          sleep [remaining, WAIT_SLEEP].min
        end
      end

      protected

      def state_keys
        [state_key]
      end

      private

      def state_key
        "lmtr-l:#{@name}"
      end

      def drain_interval_seconds
        case @options[:drain]
        when Symbol
          Limiter.interval_seconds(@options[:drain], allow_integer: false)
        when Integer
          @options[:drain]
        else
          raise ArgumentError, "drain must be Symbol or Integer (got #{@options[:drain].class})"
        end
      end

      # bucket_size / drain → ops per second.
      def drain_per_sec
        @drain_per_sec ||= @options[:bucket_size].to_f / drain_interval_seconds
      end

      def acquire
        lua(:limiter_leaky_acquire,
            keys: [state_key],
            argv: [@options[:bucket_size], drain_per_sec, ttl])
      end
    end

    # ---- Points -------------------------------------------------------
    #
    # Token-bucket with explicit `estimate:` per call. Refills at
    # `refill_per_second` capped at `initial_points`. Failure mode is
    # immediate (spec §1.4 — no sleep loop). The block is invoked with a
    # `Handle` so user code may refund/over-charge via `handle.points_used`.
    class Points < Base
      class Handle
        def initialize(limiter, estimate)
          @limiter = limiter
          @estimate = estimate
        end

        # Positive delta returns points to the bucket; negative records an
        # under-estimate. Either way, clamped to [0, cap].
        def points_used(actual)
          delta = @estimate - actual
          @limiter.send(:refund, delta)
        end
      end

      def type = :points

      # Apply refill on read so the size matches what the *next* acquire
      # would see. Stored balance only updates on acquire/refund; without
      # this, a fully-refilled bucket reports stale low numbers.
      def size
        cap = @options[:initial].to_f
        data = Wurk::Limiter.redis { |c| c.call('HMGET', state_key, 'points', 'last') }
        stored = data[0]
        return cap if stored.nil?

        last = (data[1] || ::Time.now.to_f).to_f
        elapsed = [::Time.now.to_f - last, 0.0].max
        [cap, stored.to_f + (elapsed * @options[:refill].to_f)].min
      end

      def within_limit(estimate:, &block)
        raise ArgumentError, 'block required' unless block
        raise ArgumentError, 'estimate must be positive' if estimate <= 0

        ok, _remaining = acquire(estimate)
        raise OverLimit.new(self) unless ok.to_i == 1

        handle = Handle.new(self, estimate)
        block.call(handle)
      end

      protected

      def state_keys
        [state_key]
      end

      private

      def state_key
        "lmtr-p:#{@name}"
      end

      def acquire(estimate)
        lua(:limiter_points_acquire,
            keys: [state_key],
            argv: [@options[:initial], @options[:refill], estimate, ttl])
      end

      def refund(delta)
        lua(:limiter_points_refund,
            keys: [state_key],
            argv: [delta, @options[:initial], ttl]).to_f
      end
    end

    # ---- Unlimited ----------------------------------------------------
    #
    # No-op for the tests + bypass scenarios documented in §1.8. The
    # within_limit block runs unconditionally and the introspection
    # methods all return zeros so dashboards render predictably.
    class Unlimited
      def name = 'unlimited'
      def type = :unlimited
      def options = {}
      def size = 0
      def status = {}
      def fingerprint = Digest::SHA256.hexdigest('unlimited')
      def reset = nil
      def delete = nil

      # Accept all the kwargs the other limiters take so a worker can swap
      # `limiter = Sidekiq::Limiter.unlimited` in tests without touching
      # call sites. `points`-style callers pass an `estimate:` and expect a
      # `|handle|` block param — we yield a zero-cost handle just in case.
      def within_limit(**_kwargs, &block)
        raise ArgumentError, 'block required' unless block

        if block.arity == 0
          block.call
        else
          block.call(Points::Handle.new(self, 0))
        end
      end
    end

    # ---- Server Middleware --------------------------------------------
    #
    # Catches OverLimit (and any class registered in
    # `Limiter.config.errors`), bumps `job['overrated']`, computes the
    # backoff, and reschedules to the same queue via `Client.push` with
    # `at: Time.now + backoff`. Once `overrated >= reschedule`, re-raises
    # so the normal retry/dead pipeline takes over.
    class ServerMiddleware
      include Wurk::Middleware::ServerMiddleware

      def call(_worker, job, _queue)
        yield
      rescue StandardError => e
        raise unless over_limit?(e)

        handle_over_limit(job, e)
      end

      private

      def over_limit?(exc)
        Wurk::Limiter.config.errors.any? { |k| exc.is_a?(k) }
      end

      def handle_over_limit(job, exc)
        job['overrated'] = job.fetch('overrated', 0).to_i + 1
        limiter = exc.respond_to?(:limiter) ? exc.limiter : nil
        exc.job = job if exc.respond_to?(:job=)
        reschedule_cap = (limiter && limiter.options[:reschedule]) || Wurk::Limiter::DEFAULT_RESCHEDULE
        raise exc if job['overrated'] >= reschedule_cap

        backoff_proc = (limiter && limiter.options[:backoff]) || Wurk::Limiter.config.backoff
        delay = backoff_proc.call(limiter, job, exc).to_f
        Wurk::Client.new.push(job.merge('at' => ::Time.now.to_f + delay))
      end
    end
  end
end

require_relative 'middleware'
# Server-middleware registration happens in wurk.rb after the Wurk
# `class << self` block defines `Wurk.configuration` — limiter.rb
# loads earlier than that, so trying to call it here would NoMethodError.
