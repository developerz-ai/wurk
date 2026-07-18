# frozen_string_literal: true

require_relative '../middleware'

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
    # The middleware is hot-path — every successful job pays for it. Writes are
    # pipelined in a single round-trip per job (1 HINCRBY × 2 + 1 EXPIRE per
    # bucket × 2 buckets = 6 commands, batched).
    class History
      include Wurk::Middleware::ServerMiddleware

      # Per spec §1.6 — naming mirrors the upstream constants so anyone
      # grepping the Sidekiq source for `MID_TERM` lands here.
      MID_TERM = 3 * 24 * 60 * 60      # 3 days, in seconds

      MINUTE_KEY_PREFIX = 'j|'
      DATE_FORMAT = '%Y%m%d'           # YYYYMMDD — matches Sidekiq's j| key

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
          # Best-effort: a metrics write failure must never propagate into
          # the job result. The processor already finalized the ack path.
          begin
            self.class.record(klass, duration, success: success, redis_pool: redis_pool)
          rescue StandardError => e
            handle_error(e)
          end
        end
      end

      class << self
        # Single Redis round-trip per job. `success: true` → `<klass>|p`;
        # `success: false` → `<klass>|f`. `<klass>|ms` accumulates total
        # runtime in milliseconds for *both* outcomes (so an operator can
        # ask "how much wall-clock time has FooJob consumed?" without
        # branching on outcome).
        def record(klass, duration_ms, success:, redis_pool: nil, at: ::Time.now)
          return if klass.nil? || klass.empty?

          ms = duration_ms.to_i
          ms = 0 if ms.negative?
          buckets = { minute: minute_key(at), hour: hour_key(klass, at) }
          with_pool(redis_pool) { |conn| pipeline_write(conn, klass, ms, success, buckets) }
          nil
        end

        # The minute bucket carries per-class `<klass>|p|f|ms` fields; the
        # hourly bucket is already class-scoped so its fields are bare
        # `p|f|ms`. Pipeline all 6 commands in one round-trip.
        def pipeline_write(conn, klass, ms, success, buckets)
          outcome = success ? 'p' : 'f'
          class_outcome = "#{klass}|#{outcome}"
          class_ms = "#{klass}|ms"
          conn.pipelined do |pipe|
            incr_bucket(pipe, buckets[:minute], [class_outcome, class_ms, ms, MID_TERM])
            incr_bucket(pipe, buckets[:hour], [outcome, 'ms', ms, MID_TERM])
          end
        end

        def incr_bucket(pipe, key, parts)
          outcome_field, ms_field, ms, ttl = parts
          pipe.call('HINCRBY', key, outcome_field, 1)
          pipe.call('HINCRBY', key, ms_field, ms)
          pipe.call('EXPIRE', key, ttl)
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
      end

      private

      def monotonic_ms
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :float_millisecond)
      end

      def handle_error(err)
        cfg = config || Wurk.configuration
        cfg.handle_exception(err, context: 'Wurk::Metrics::History')
      end

      def self.with_pool(pool, &)
        if pool
          pool.with(&)
        else
          Wurk.redis(&)
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
