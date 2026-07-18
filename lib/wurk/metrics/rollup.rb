# frozen_string_literal: true

require_relative '../component'
require_relative '../timer_loop'
require_relative 'history'

module Wurk
  module Metrics
    # Leader-only background thread that rolls the per-class minute buckets
    # written by Wurk::Metrics::History (`j|YYMMDD|H:M`) up into compact,
    # cluster-total time-series buckets the dashboard "throughput" / "failures"
    # charts read directly:
    #
    #   jr|1m|<epoch>   HASH {p,f,ms}   TTL 24h   (1-minute resolution)
    #   jr|5m|<epoch>   HASH {p,f,ms}   TTL 7d    (5-minute resolution)
    #   jr|1h|<epoch>   HASH {p,f,ms}   TTL 30d   (1-hour resolution)
    #
    # `<epoch>` is the UTC start-of-bucket as integer seconds. Totals are summed
    # across every job class, so a 30-day chart reads ~720 small hashes instead
    # of fanning out over ~43k per-class minute keys.
    #
    # Every write is an idempotent HSET. Each tick recomputes the trailing few
    # 1m buckets from the source minute hash, then recomputes the coarse buckets
    # from their 1m children. Re-running a tick (a missed tick, a leadership
    # change, a late metric write) converges to the same totals — it never
    # double-counts. Storage is bounded purely by the per-bucket TTLs; see
    # docs/metrics-history.md for the retention math.
    class Rollup
      include Component

      PREFIX = 'jr'

      # bucket => [step_seconds, ttl_seconds]. The retention is the issue's
      # spec: 1m kept 24h, 5m kept 7d, 1h kept 30d.
      BUCKETS = {
        '1m' => [60,   24 * 60 * 60],
        '5m' => [300,  7 * 24 * 60 * 60],
        '1h' => [3600, 30 * 24 * 60 * 60]
      }.freeze

      COARSE = %w[5m 1h].freeze

      DEFAULT_TICK_SECONDS = 60
      # Re-roll the last N completed minutes from source on every tick
      # (idempotent). This self-heals a leadership failover / restart or a late
      # metric write up to N minutes old — the source `j|…` buckets live 3 days,
      # so re-reading them folds the gap back in. Only outages longer than this
      # leave a hole that ages out with the bucket TTL (best-effort metrics).
      LOOKBACK_MINUTES = 15

      def self.bucket_key(bucket, epoch)
        "#{PREFIX}|#{bucket}|#{epoch}"
      end

      def initialize(config)
        @config = config
        @timer = TimerLoop.new(config[:metrics_rollup_interval] || DEFAULT_TICK_SECONDS)
        @thread = nil
      end

      def start
        @thread ||= safe_thread('metrics-rollup') { @timer.run { tick } } # rubocop:disable Naming/MemoizedInstanceVariableName
      end

      def terminate
        @timer.terminate
      end

      # Leader-gated: only the elected leader writes the cluster-total series,
      # so N workers don't each HSET the same buckets every minute.
      def tick(now: ::Time.now)
        return unless leader?

        roll(now)
      rescue StandardError => e
        handle_exception(e, { context: 'metrics-rollup' })
      end

      # One rollup pass, bypassing the leader gate and the sleep loop. Public so
      # deterministic specs and a manual "roll now" can drive it directly.
      def roll(now = ::Time.now)
        cur_min = floor_min(now)
        minutes = (1..LOOKBACK_MINUTES).map { |i| cur_min - (i * 60) }
        minutes.each { |epoch_min| write_minute_bucket(epoch_min) }
        recompute_coarse(minutes)
        nil
      end

      private

      def write_minute_bucket(epoch_min)
        store('1m', epoch_min, minute_total(epoch_min))
      end

      # Sum every class's p/f/ms in the source minute hash into a single total.
      def minute_total(epoch_min)
        raw = redis { |c| c.call('HGETALL', source_minute_key(epoch_min)) }
        raw = raw.each_slice(2).to_h if raw.is_a?(::Array)
        total = { p: 0, f: 0, ms: 0 }
        raw.each do |field, value|
          _klass, kind = field.split('|', 2)
          total[kind.to_sym] += value.to_i if kind && total.key?(kind.to_sym)
        end
        total
      end

      # Re-sum each coarse bucket from its 1m children, for every window the
      # just-written minutes touched (covers the current window plus any
      # boundary the lookback crossed).
      def recompute_coarse(minutes)
        COARSE.each do |bucket|
          step, = BUCKETS[bucket]
          minutes.map { |m| (m / step) * step }.uniq.each { |w| store(bucket, w, child_total(w, step)) }
        end
      end

      def child_total(window_start, step)
        keys = (window_start...(window_start + step)).step(60).map { |s| self.class.bucket_key('1m', s) }
        sum_pfms(redis { |c| c.pipelined { |p| keys.each { |k| p.call('HMGET', k, 'p', 'f', 'ms') } } })
      end

      def sum_pfms(rows)
        rows.each_with_object({ p: 0, f: 0, ms: 0 }) do |(p, f, ms), total|
          total[:p] += p.to_i
          total[:f] += f.to_i
          total[:ms] += ms.to_i
        end
      end

      # Skip empty buckets so an idle cluster doesn't litter Redis with zero
      # rows; a missing bucket reads back as zero on the query side anyway.
      def store(bucket, epoch, total)
        return if total.values.all?(&:zero?)

        _step, ttl = BUCKETS[bucket]
        key = self.class.bucket_key(bucket, epoch)
        redis do |c|
          c.call('HSET', key, 'p', total[:p], 'f', total[:f], 'ms', total[:ms])
          c.call('EXPIRE', key, ttl)
        end
      end

      def source_minute_key(epoch_min)
        Wurk::Metrics::History.minute_key(::Time.at(epoch_min).utc)
      end

      def floor_min(time)
        (time.to_i / 60) * 60
      end
    end
  end
end
