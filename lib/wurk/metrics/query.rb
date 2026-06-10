# frozen_string_literal: true

require_relative '../keys'
require_relative 'history'
require_relative 'rollup'
require_relative 'queue_rollup'

module Wurk
  module Metrics
    # Read-side for the per-class HASH bucket schema written by
    # `Wurk::Metrics::History`. Backs the Web UI's history pane and any
    # external dashboarding code; both rely on the same HGETALL fan-out
    # over a contiguous range of minute / hour keys.
    #
    # Window caps are spec-enforced:
    #
    #   minutes ≤ 480  (8h — same as the 10-minute rollup retention)
    #   hours   ≤ 72   (3d — same as MID_TERM retention)
    #
    # A wider window has no data to read anyway (the buckets are TTL'd out),
    # so we fail loudly rather than silently returning sparse results.
    module Query # rubocop:disable Metrics/ModuleLength
      MAX_MINUTES = 480
      MAX_HOURS = 72
      TOTAL_FIELDS = %w[p f ms].freeze
      private_constant :TOTAL_FIELDS

      class WindowTooWide < ::ArgumentError; end

      module_function

      # Aggregate per-job-class totals over a recent window of minute
      # buckets. Returns array of `[class_name, {p:, f:, ms:}]` tuples
      # sorted by volume (p + f) descending so the UI's "top jobs" table
      # renders without a second sort pass.
      def top_jobs(class_filter: nil, minutes: 60, hours: nil, now: ::Time.now)
        minutes = hours * 60 if hours
        cap_hours!(hours) if hours
        rows = aggregate_minutes(now, cap_minutes!(minutes)).to_a
        rows = rows.select { |(k, _)| k.start_with?(class_filter) } if class_filter && !class_filter.empty?
        rows.sort_by { |(_k, s)| -(s[:p] + s[:f]) }
      end

      # Per-class time-series. `minutes` reads the per-minute bucket; `hours`
      # reads the per-class hourly bucket (separate keys per spec, so a long
      # window doesn't fan out over 4320 minute hashes).
      def for_job(klass, minutes: nil, hours: nil, now: ::Time.now)
        validate_for_job!(klass, minutes, hours)
        minutes ? minute_series(klass, now, cap_minutes!(minutes)) : hour_series(klass, now, cap_hours!(hours))
      end

      # Cluster-total time-series for the dashboard throughput/failures charts,
      # read from the compact buckets written by Wurk::Metrics::Rollup. `bucket`
      # is '1m'/'5m'/'1h'; `window_seconds` is clamped to that bucket's
      # retention. Returns `[{at:, p:, f:, ms:}, ...]` oldest→newest, gap-filled
      # with zeros so a chart has a continuous x-axis.
      def history(bucket, window_seconds, now: ::Time.now)
        step, ttl = bucket_spec!(bucket)
        starts = bucket_starts(now, step, clamp_history_window!(window_seconds, ttl))
        rows = pipeline_hmget(starts.map { |s| Wurk::Metrics::Rollup.bucket_key(bucket, s) }, %w[p f ms])
        starts.zip(rows).map { |at, (p, f, ms)| { at: at, p: p.to_i, f: f.to_i, ms: ms.to_i } }
      end

      # Per-queue size/latency gauge time-series written by
      # Metrics::QueueRollup. `bucket` is '1m'/'5m'/'1h'; `window_seconds` is
      # clamped to the bucket's retention. Returns one entry per live queue
      # (or the explicit `queues:` list) — `[{name:, points: [{at:, size:,
      # latency:}, …]}, …]` — oldest→newest, gap-filled with zeros so a chart
      # has a continuous x-axis. Capped at MAX_QUEUE_SERIES queues to bound the
      # payload; the cap is logged-free because queue cardinality is small.
      def queue_history(bucket, window_seconds, queues: nil, now: ::Time.now)
        step, ttl = bucket_spec!(bucket)
        starts = bucket_starts(now, step, clamp_history_window!(window_seconds, ttl))
        names = queue_names(queues)
        return [] if names.empty?

        hashes = queue_bucket_hashes(bucket, starts)
        names.map { |name| { name: name, points: queue_points(name, starts, hashes) } }
      end

      def queue_bucket_hashes(bucket, starts)
        pipeline_hgetall(starts.map { |s| Wurk::Metrics::QueueRollup.bucket_key(bucket, s) })
          .map { |h| h.is_a?(::Array) ? h.each_slice(2).to_h : (h || {}) }
      end

      MAX_QUEUE_SERIES = 25

      def queue_names(queues)
        names = queues || Wurk.redis { |c| c.call('SMEMBERS', Wurk::Keys::QUEUES_SET) }
        names.sort.first(MAX_QUEUE_SERIES)
      end

      def queue_points(name, starts, hashes)
        size_field = "#{name}|#{Wurk::Metrics::QueueRollup::SIZE_KIND}"
        lat_field  = "#{name}|#{Wurk::Metrics::QueueRollup::LAT_KIND}"
        starts.zip(hashes).map do |at, hash|
          { at: at, size: hash[size_field].to_i, latency: (hash[lat_field] || 0).to_f }
        end
      end

      def bucket_spec!(bucket)
        Wurk::Metrics::Rollup::BUCKETS.fetch(bucket) do
          raise ArgumentError, "bucket must be one of #{Wurk::Metrics::Rollup::BUCKETS.keys.inspect}"
        end
      end

      def clamp_history_window!(window_seconds, ttl)
        window = Integer(window_seconds)
        raise ArgumentError, 'window must be positive' if window <= 0

        [window, ttl].min
      end

      # The last `window/step` step-aligned bucket starts, oldest→newest, so
      # they match the keys the rollup writes.
      def bucket_starts(now, step, window)
        last = (now.to_i / step) * step
        (0...(window / step)).map { |i| last - (i * step) }.reverse
      end

      def validate_for_job!(klass, minutes, hours)
        raise ArgumentError, 'klass required' if klass.nil? || klass.empty?
        raise ArgumentError, 'pass exactly one of minutes: or hours:' if minutes && hours
        raise ArgumentError, 'pass minutes: or hours:' if minutes.nil? && hours.nil?
      end

      def cap_minutes!(minutes)
        check_window!(Integer(minutes), MAX_MINUTES, 'minutes')
      end

      def cap_hours!(hours)
        check_window!(Integer(hours), MAX_HOURS, 'hours')
      end

      def check_window!(value, max, label)
        raise ArgumentError, "#{label} must be positive" if value <= 0
        raise WindowTooWide, "#{label} must be <= #{max} (got #{value})" if value > max

        value
      end

      def aggregate_minutes(now, minutes)
        totals = ::Hash.new { |h, k| h[k] = { p: 0, f: 0, ms: 0 } }
        pipeline_hgetall(minute_keys(now, minutes)).each { |hash| accumulate!(totals, hash) }
        totals
      end

      def accumulate!(totals, hash)
        return if hash.nil? || hash.empty?

        hash.each do |field, value|
          klass, kind = field.split('|', 2)
          next unless kind && TOTAL_FIELDS.include?(kind)

          totals[klass][kind.to_sym] += Integer(value)
        end
      end

      def minute_series(klass, now, minutes)
        rows = pipeline_hmget(minute_keys(now, minutes), %W[#{klass}|p #{klass}|f #{klass}|ms])
        zip_rows(minute_timestamps(now, minutes), rows)
      end

      def hour_series(klass, now, hours)
        timestamps = hour_timestamps(now, hours)
        keys = timestamps.map { |t| Wurk::Metrics::History.hour_key(klass, t) }
        zip_rows(timestamps, pipeline_hmget(keys, %w[p f ms]))
      end

      def zip_rows(timestamps, rows)
        timestamps.zip(rows).map { |at, (p, f, ms)| { at: at, p: p.to_i, f: f.to_i, ms: ms.to_i } }
      end

      def minute_keys(now, minutes)
        minute_timestamps(now, minutes).map { |t| Wurk::Metrics::History.minute_key(t) }
      end

      # Truncate to the minute so the bucket boundary matches what the
      # writer used. Fractional-second drift would otherwise pull in an
      # unrelated minute on the edge of the window.
      def minute_timestamps(now, minutes)
        floor = floor_to(now, :min)
        (0...minutes).map { |i| floor - (i * 60) }.reverse
      end

      def hour_timestamps(now, hours)
        floor = floor_to(now, :hour)
        (0...hours).map { |i| floor - (i * 3600) }.reverse
      end

      def floor_to(time, unit)
        t = time.utc
        case unit
        when :min  then ::Time.utc(t.year, t.month, t.day, t.hour, t.min)
        when :hour then ::Time.utc(t.year, t.month, t.day, t.hour)
        end
      end

      def pipeline_hgetall(keys)
        return [] if keys.empty?

        Wurk.redis { |c| c.pipelined { |p| keys.each { |k| p.call('HGETALL', k) } } }
      end

      def pipeline_hmget(keys, fields)
        return [] if keys.empty?

        Wurk.redis { |c| c.pipelined { |p| keys.each { |k| p.call('HMGET', k, *fields) } } }
      end
    end
  end
end
