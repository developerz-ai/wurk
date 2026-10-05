# frozen_string_literal: true

require_relative '../job'
require_relative '../middleware'
require_relative '../pool_checkout'
require_relative 'accumulator'
require_relative 'histogram'

module Wurk
  module Metrics
    # Server middleware that records per-job-class execution metrics into the
    # same Redis buckets Sidekiq 8.1's ExecutionTracker writes, so history
    # survives a swap in either direction and Sidekiq's own `Metrics::Query`
    # reads what Wurk wrote (spec: docs/target/sidekiq-free.md §1.6, §20).
    #
    #   j|YYMMDD|H:MM   HASH  per-minute bucket, TTL = SHORT_TERM (8h)
    #   j|YYMMDD|H:M    HASH  10-minute bucket (minute's tens digit), TTL = MID_TERM (3d)
    #     <klass>|p     INT   executions, failures included
    #     <klass>|f     INT   failures
    #     <klass>|ms    INT   total ms of the executions that did not fail
    #   h|<klass>-D-H:M BITFIELD per-minute runtime histogram (Metrics::Histogram)
    #
    # The two `j|` shapes cannot collide: the minute is always two digits
    # (`14:05`), the 10-minute bucket always one (`14:0`). `<klass>` is the
    # `wrapped` class for ActiveJob payloads, like upstream.
    #
    # Every bucket TTL is set on every write (not NX), as upstream does.
    #
    # The middleware is hot-path — every job pays for it — so it does not touch
    # Redis at all. Each execution folds into a process-wide Accumulator and
    # Wurk::Metrics::Flusher writes the whole tree out every FLUSH_INTERVAL.
    class History
      include Wurk::Middleware::ServerMiddleware

      # Upstream's ExecutionTracker constants, same names.
      MID_TERM = 3 * 24 * 60 * 60
      SHORT_TERM = 8 * 60 * 60

      MINUTE_KEY_FORMAT = 'j|%y%m%d|%-H:%M'

      # Ceiling on how stale an unflushed counter can be, in seconds. A
      # constant, never a config knob: it exists to bound the dashboard's lag,
      # not to be tuned. Sidekiq — the engine these numbers get compared
      # against — flushes its own process stats on a 10s heartbeat and writes
      # nothing per job, so this is the tighter of the two. Signed off in
      # docs/plans/2026/08/06/101-faster-than-sidekiq/00-semantics-signoff.md §2.
      FLUSH_INTERVAL = 5

      # Process-wide, like Processor::PROCESSED — the counters belong to the
      # process, not to a middleware instance (the chain builds one per capsule)
      # and not to a job.
      ACCUMULATOR = Accumulator.new

      def call(_worker, job, _queue)
        klass = job['wrapped'] || job['class']
        started = monotonic_ms
        success = false
        begin
          result = yield
          success = true
          result
        rescue Wurk::Job::Interrupted, Wurk::Job::DeadlineExceeded
          # Neither is the job failing. A cooperative interruption is not a
          # failure: InterruptHandler self-prepends, so it sits *outside* this
          # middleware, Interrupted passes through here before it becomes a
          # JobRetry::Skip, and without this arm one interrupted IterableJob
          # books a spurious `<klass>|f` (#394). Upstream's
          # ExecutionTracker#track books `p` + `ms` for that Skip and reserves
          # `f` for a real exception; `p` is the bucket for "reached perform and
          # didn't error", so the resumed run booking a second `p` is the
          # oracle's behavior, not a rounding error. Signed off in
          # docs/plans/2026/08/07/101-beyond-sidekiq/00-semantics-signoff.md §1.
          #
          # A job cut by its absolute deadline lands in the same bucket for a
          # plainer reason: Middleware::Expiry, also outside this one, catches
          # that raise and books the job `expired`. Booking `f` here too would
          # put one abandoned job in two of the three counts an operator
          # subtracts (executed = processed - failed - expired), and would make
          # it the only expired job that also reads as failed — the ones dropped
          # before `perform` never reach this middleware at all.
          success = true
          raise
        ensure
          duration = (monotonic_ms - started).round
          # Best-effort: a metrics failure must never propagate into the job
          # result. The processor already finalized the ack path. Recording is
          # in-memory now, so what this catches is a bad payload (a `class` that
          # is not a String) rather than a Redis blip — the Redis half moved to
          # Flusher, which reports on its own thread.
          begin
            self.class.record(klass, duration, success: success, redis_pool: redis_pool)
          rescue StandardError => e
            handle_error(e)
          end
        end
      end

      class << self
        # No Redis. Every call books `<klass>|p`; `success: false` also books
        # `<klass>|f`; `success: true` adds the runtime to `<klass>|ms` and the
        # histogram (Accumulator has the why).
        #
        # `at:` defaults to nil rather than `::Time.now`: this runs once per job
        # and the bucket only needs whole UTC minutes, which #minute_bucket
        # reads straight off the clock as an Integer.
        def record(klass, duration_ms, success:, redis_pool: nil, at: nil)
          return if klass.nil? || klass.empty?

          ms = duration_ms.to_i
          ms = 0 if ms.negative?
          ACCUMULATOR.add(redis_pool, klass, minute_bucket(at), ms, success)
          nil
        end

        # Drains an accumulator into Redis, one pipeline per pool. Raises the
        # first pool's failure after every other pool has had its turn —
        # Wurk::Metrics::Flusher owns turning that into an error-handler call.
        #
        # Only the *failed* pool's counts are merged back. Putting the whole
        # drained tree back would re-send the writes that already landed, and
        # HINCRBY would count them twice.
        #
        # The argument is a collaborator, not an option: a process has exactly
        # one accumulator and nothing in wurk passes a second. Tests pass their
        # own so a deliberately broken pool cannot leak into a parallel test's
        # flush through the process-wide one.
        #
        # A shut-down pool is the one failure that is *terminal*: ConnectionPool
        # #shutdown is one-way (see Capsule#reset_redis_pools!), so its counts
        # can never be written by anyone. Merging them back would re-raise on
        # every tick for the life of the process — a permanent 5s error-handler
        # loop over a condition no operator can act on. The accumulator survives
        # the pool that fed it (a fork inherits it; `reset_redis_pools!` is host-
        # callable), so drop those counts, exactly as the retry cap already
        # drops a window Redis stayed down through.
        def flush(accumulator = ACCUMULATOR)
          error = nil
          accumulator.drain.each do |pool, minutes|
            write(pool, minutes)
          rescue ConnectionPool::PoolShuttingDownError
            next
          rescue StandardError => e
            accumulator.merge_back(pool, minutes)
            error = e
          end
          raise error if error

          nil
        end

        # Public formatters — Wurk::Metrics::Query reuses these so the two
        # cannot drift on bucket-naming convention.
        def minute_key(time)
          time.utc.strftime(MINUTE_KEY_FORMAT)
        end

        # Upstream derives the 10-minute bucket by chopping the minute key's
        # last digit: `j|250214|8:43` → `j|250214|8:4`.
        def ten_minute_key(time)
          minute_key(time).chop
        end

        private

        # Whole UTC minutes since the epoch. Integer arithmetic on a raw clock
        # read, so nothing is allocated per job.
        def minute_bucket(at)
          return ::Process.clock_gettime(::Process::CLOCK_REALTIME, :second) / 60 unless at

          at.to_i / 60
        end

        def write(pool, minutes)
          with_pool(pool) do |conn|
            conn.pipelined do |pipe|
              minutes.each do |minute, classes|
                at = ::Time.at(minute * 60).utc
                short = minute_key(at)
                keys = [short, short.chop]
                classes.each { |klass, counts| write_class(pipe, keys, at, klass, counts) }
              end
            end
          end
        end

        # `keys` is [minute key, 10-minute key].
        def write_class(pipe, keys, at, klass, counts)
          fields = ["#{klass}|p", "#{klass}|f", "#{klass}|ms"]
          incr_bucket(pipe, keys[1], fields, counts, MID_TERM)
          incr_bucket(pipe, keys[0], fields, counts, SHORT_TERM)
          return unless counts[3]

          pipe.call(*Histogram.incr_command(klass, at, counts[3]))
          pipe.call('EXPIRE', Histogram.key(klass, at), Histogram::HISTOGRAM_TTL)
        end

        # Upstream's tracker only ever creates the fields it has a count for:
        # `f` when something failed, `ms` when something succeeded (by zero
        # included). `HINCRBY <field> 0` beyond that would materialize a
        # counter Sidekiq never writes.
        def incr_bucket(pipe, key, fields, counts, ttl)
          processed, failed, ms = counts
          pipe.call('HINCRBY', key, fields[0], processed)
          pipe.call('HINCRBY', key, fields[1], failed) if failed.positive?
          pipe.call('HINCRBY', key, fields[2], ms) if processed > failed
          pipe.call('EXPIRE', key, ttl)
        end
      end

      private

      def monotonic_ms
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :float_millisecond)
      end

      def handle_error(err)
        cfg = config || Wurk.configuration
        cfg.handle_exception(err, context: 'Wurk::Metrics::History')
      end

      def self.with_pool(pool, idempotent: false, &)
        if pool
          PoolCheckout.with(pool, idempotent, &)
        else
          Wurk.redis(idempotent:, &)
        end
      end
      private_class_method :with_pool
    end

    # Sidekiq exposes this as `Sidekiq::Metrics::Middleware` (via
    # `Sidekiq::Metrics`, aliased to `Wurk::Metrics` in compat). Mirror that
    # name so the drop-in constant resolves. Spec: docs/target/sidekiq-free.md §10.3.
    Middleware = History
  end
end
