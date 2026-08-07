# frozen_string_literal: true

require_relative '../middleware'
require_relative '../pool_checkout'
require_relative 'accumulator'

module Wurk
  module Metrics
    # Ent feature parity (§5): server middleware that records per-job-class
    # execution metrics into Redis time-buckets. The on-the-wire schema is
    # wire-compat with Sidekiq's history pane — Sidekiq keys the per-minute
    # HASH as `j|<YYYYMMDD>|<H>:<M>`, so dashboards (and Sidekiq data migrated
    # in place) keep resolving against the same key after a drop-in swap.
    #
    # Bucket layout (spec: docs/target/sidekiq-free.md §1.6):
    #
    #   j|YYYYMMDD|H:M    HASH   per-minute bucket, TTL = MID_TERM (3 days)
    #     <klass>|p       INT    processed count
    #     <klass>|f       INT    failed count
    #     <klass>|ms      INT    total ms spent
    #
    #   <klass>-YYYYMMDD-H  HASH per-class hourly histogram, TTL = MID_TERM
    #
    # We deliberately do NOT write a `H:m0` 10-minute rollup. Its key format
    # collides with the real minute-0 bucket, so rolling x1..x9 into it turns
    # that minute's value into a decade total — and the read side (Query) then
    # sums the minute-0 bucket alongside x1..x9 and double-counts. Sidekiq
    # itself doesn't keep that rollup (the daily/hourly rollups are commented
    # out in its ExecutionTracker); Query reads the last N per-minute keys.
    #
    # Every bucket TTL is set on every write (not NX): as long as a class keeps
    # running we keep its bucket around for the retention window measured from
    # *last write*, not from first write. So we EXPIRE unconditionally.
    #
    # The middleware is hot-path — every job pays for it — so it does not touch
    # Redis at all. Each execution folds into a process-wide Accumulator and
    # Wurk::Metrics::Flusher writes the whole tree out every FLUSH_INTERVAL, in
    # the same 6-commands-per-(class, minute) shape the per-job pipeline sent.
    class History
      include Wurk::Middleware::ServerMiddleware

      # Per spec §1.6 — naming mirrors the upstream constants so anyone
      # grepping the Sidekiq source for `MID_TERM` lands here.
      MID_TERM = 3 * 24 * 60 * 60      # 3 days, in seconds

      MINUTE_KEY_PREFIX = 'j|'
      DATE_FORMAT = '%Y%m%d'           # YYYYMMDD — matches Sidekiq's j| key

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

      # Hourly buckets are already class-scoped, so their fields are bare.
      HOUR_FIELDS = %w[p f ms].freeze

      def call(_worker, job, _queue)
        klass = job['class']
        started = monotonic_ms
        success = false
        begin
          result = yield
          success = true
          result
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
        # No Redis. `success: true` → `<klass>|p`; `success: false` →
        # `<klass>|f`. `<klass>|ms` accumulates total runtime in milliseconds
        # for *both* outcomes (so an operator can ask "how much wall-clock time
        # has FooJob consumed?" without branching on outcome).
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
        def flush(accumulator = ACCUMULATOR)
          error = nil
          accumulator.drain.each do |pool, minutes|
            write(pool, minutes)
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
          t = time.utc
          format("#{MINUTE_KEY_PREFIX}%<date>s|%<hr>d:%<min>d",
                 date: t.strftime(DATE_FORMAT), hr: t.hour, min: t.min)
        end

        def hour_key(klass, time)
          t = time.utc
          "#{klass}-#{t.strftime(DATE_FORMAT)}-#{t.hour}"
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
                key = minute_key(at)
                classes.each { |klass, counts| write_class(pipe, key, at, klass, counts) }
              end
            end
          end
        end

        def write_class(pipe, bucket_key, at, klass, counts)
          incr_bucket(pipe, bucket_key, ["#{klass}|p", "#{klass}|f", "#{klass}|ms"], counts)
          incr_bucket(pipe, hour_key(klass, at), HOUR_FIELDS, counts)
        end

        # `p`/`f` are emitted only when non-zero, so a bucket ends up with the
        # exact field set the per-job path produced: `HINCRBY <field> 0` would
        # materialize a counter no unbatched write ever created, and the read
        # side would start reporting a `f: 0` series for classes that have never
        # failed. `ms` is unconditional — the per-job path always incremented
        # it, including by zero.
        def incr_bucket(pipe, key, fields, counts)
          processed, failed, ms = counts
          pipe.call('HINCRBY', key, fields[0], processed) if processed.positive?
          pipe.call('HINCRBY', key, fields[1], failed) if failed.positive?
          pipe.call('HINCRBY', key, fields[2], ms)
          pipe.call('EXPIRE', key, MID_TERM)
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
