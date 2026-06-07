# frozen_string_literal: true

require_relative '../middleware'

module Wurk
  module Metrics
    # Ent feature parity (§5): server middleware that records per-job-class
    # execution metrics into Redis time-buckets. The on-the-wire schema is
    # wire-compat with Sidekiq 8.x's history pane so dashboards built against
    # `j|YYMMDD|H:M` HASH keys keep working unchanged.
    #
    # Bucket layout (spec: docs/target/sidekiq-free.md §1.6):
    #
    #   j|YYMMDD|H:M    HASH   per-minute bucket, TTL = MID_TERM (3 days)
    #     <klass>|p     INT    processed count
    #     <klass>|f     INT    failed count
    #     <klass>|ms    INT    total ms spent
    #
    #   j|YYMMDD|H:m0   HASH   10-minute rollup (last digit zeroed),
    #                          TTL = SHORT_TERM (8 hours) — short window for
    #                          quick aggregate queries without scanning 600 minute keys.
    #
    #   <klass>-YYMMDD-H  HASH per-class hourly histogram, TTL = MID_TERM
    #
    # Every bucket TTL is set on first write (EXPIRE NX-equivalent: only when
    # the HASH was newly created in this call) — re-asserting TTL on every
    # write would keep the bucket alive indefinitely while traffic continues,
    # but that's the desired behavior here: as long as a class keeps running,
    # we keep the minute bucket around for the retention window measured from
    # *last write*, not from first write. So we EXPIRE unconditionally.
    #
    # The middleware is hot-path — every successful job pays for it. Writes
    # are pipelined in a single round-trip per job (1 HINCRBY × 3 + 1 EXPIRE
    # per bucket × 3 buckets = 12 commands, batched).
    class History
      include Wurk::Middleware::ServerMiddleware

      # Per spec §1.6 — naming mirrors the upstream constants so anyone
      # grepping the Sidekiq source for `MID_TERM` lands here.
      MID_TERM = 3 * 24 * 60 * 60      # 3 days, in seconds
      SHORT_TERM = 8 * 60 * 60         # 8 hours, in seconds

      MINUTE_KEY_PREFIX = 'j|'
      DATE_FORMAT = '%y%m%d'           # YYMMDD — two-digit year per spec

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
          buckets = { minute: minute_key(at), rollup: rollup_key(at), hour: hour_key(klass, at) }
          with_pool(redis_pool) { |conn| pipeline_write(conn, klass, ms, success, buckets) }
          nil
        end

        # Minute + 10-min rollup share a per-class `|p|f|ms` field layout;
        # the hourly bucket is already class-scoped so its fields are bare
        # `p|f|ms`. Pipeline all 9 commands in one round-trip.
        def pipeline_write(conn, klass, ms, success, buckets)
          outcome = success ? 'p' : 'f'
          class_outcome = "#{klass}|#{outcome}"
          class_ms = "#{klass}|ms"
          conn.pipelined do |pipe|
            incr_bucket(pipe, buckets[:minute], [class_outcome, class_ms, ms, MID_TERM])
            # The minute key and the 10-min rollup key coincide whenever the
            # minute ends in 0 (rollup zeroes the last digit). Writing both
            # would double-count the shared field — the minute write above
            # already lands on it — so skip the rollup write then. Minutes
            # x1..x9 still accumulate into the x0 rollup key as normal.
            unless buckets[:rollup] == buckets[:minute]
              incr_bucket(pipe, buckets[:rollup], [class_outcome, class_ms, ms, SHORT_TERM])
            end
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

        def rollup_key(time)
          t = time.utc
          format("#{MINUTE_KEY_PREFIX}%<date>s|%<hr>d:%<min>d",
                 date: t.strftime(DATE_FORMAT), hr: t.hour, min: (t.min / 10) * 10)
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
