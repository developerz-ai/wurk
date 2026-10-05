# frozen_string_literal: true

require_relative '../keys'
require_relative 'rollup'
require_relative 'queue_rollup'

module Wurk
  module Metrics
    # Wurk's dashboard JSON reads, extended onto Metrics::Query as class
    # methods: flat rows gap-filled with zeros so a chart has a continuous
    # x-axis, and `Query::WindowTooWide` instead of upstream's silent clamp so
    # the API can answer 400. The Sidekiq-shaped API is Query's instance side.
    module DashboardSeries
      TOTAL_FIELDS = %w[p f ms].freeze

      # Dashboard top-N: `[[klass, {p:, f:, ms:}], …]` over the window,
      # busiest (`p`, which counts failures) first. `class_filter` is a
      # class-name prefix. Sums straight off the buckets rather than through
      # Query#top_jobs, whose per-bucket series a table never shows.
      def top_jobs(class_filter: nil, minutes: 60, hours: nil, now: ::Time.now)
        _stamps, keys = window_buckets(minutes, hours, now)
        rows = sum_totals(pipeline_hgetall(keys)).to_a
        rows.select! { |(klass, _)| klass.start_with?(class_filter) } if class_filter && !class_filter.empty?
        rows.sort_by { |(_k, sums)| -sums[:p] }
      end

      # Dashboard per-class series, oldest→newest, gap-filled:
      # `[{at:, p:, f:, ms:}, …]`. `minutes:` gives one row per minute,
      # `hours:` one per 10-minute bucket.
      def for_job(klass, minutes: nil, hours: nil, now: ::Time.now)
        validate_for_job!(klass, minutes, hours)
        stamps, keys = window_buckets(minutes, hours, now)
        pfms_rows(stamps, pipeline_hmget(keys, TOTAL_FIELDS.map { |f| "#{klass}|#{f}" }))
      end

      # Cluster-total time-series for the dashboard throughput/failures charts,
      # read from the compact buckets written by Wurk::Metrics::Rollup. `bucket`
      # is '1m'/'5m'/'1h'; `window_seconds` is clamped to that bucket's
      # retention. Returns `[{at:, p:, f:, ms:}, ...]` oldest→newest, gap-filled
      # with zeros so a chart has a continuous x-axis.
      def history(bucket, window_seconds, now: ::Time.now)
        step, ttl = bucket_spec!(bucket)
        starts = bucket_starts(now, step, clamp_history_window!(window_seconds, ttl))
        pfms_rows(starts, pipeline_hmget(starts.map { |s| Rollup.bucket_key(bucket, s) }, TOTAL_FIELDS))
      end

      # Per-queue size/latency gauge time-series written by
      # Metrics::QueueRollup. Returns one entry per live queue (or the
      # explicit `queues:` list, capped at MAX_QUEUE_SERIES) —
      # `[{name:, points: [{at:, size:, latency:}, …]}, …]` — oldest→newest,
      # gap-filled with zeros.
      def queue_history(bucket, window_seconds, queues: nil, now: ::Time.now)
        step, ttl = bucket_spec!(bucket)
        starts = bucket_starts(now, step, clamp_history_window!(window_seconds, ttl))
        names = queue_names(queues)
        return [] if names.empty?

        hashes = queue_bucket_hashes(bucket, starts)
        names.map { |name| { name: name, points: queue_points(name, starts, hashes) } }
      end

      private

      # Bucket start times oldest→newest and their keys: one per minute for
      # `minutes`, one per 10 minutes for `hours` (which wins when both given).
      def window_buckets(minutes, hours, now)
        stride, keyproc = Query::ROLLUPS.fetch(hours ? :hourly : :minutely)
        count = hours ? cap_hours!(hours) * 6 : cap_minutes!(minutes)
        stamps = bucket_starts(now, stride, count * stride).map { |s| ::Time.at(s).utc }
        [stamps, stamps.map(&keyproc)]
      end

      def sum_totals(hashes)
        totals = ::Hash.new { |h, k| h[k] = { p: 0, f: 0, ms: 0 } }
        hashes.each do |raw|
          hash_reply(raw).each do |field, value|
            klass, kind = field.split('|', 2)
            totals[klass][kind.to_sym] += value.to_i if kind && TOTAL_FIELDS.include?(kind)
          end
        end
        totals
      end

      def hash_reply(raw)
        raw.is_a?(::Array) ? raw.each_slice(2).to_h : (raw || {})
      end

      def pfms_rows(stamps, rows)
        stamps.zip(rows).map { |at, (p, f, ms)| { at: at, p: p.to_i, f: f.to_i, ms: ms.to_i } }
      end

      def queue_bucket_hashes(bucket, starts)
        pipeline_hgetall(starts.map { |s| QueueRollup.bucket_key(bucket, s) }).map { |h| hash_reply(h) }
      end

      def queue_names(queues)
        names = queues || Wurk.redis { |c| c.call('SMEMBERS', Wurk::Keys::QUEUES_SET) }
        names.sort.first(Query::MAX_QUEUE_SERIES)
      end

      def queue_points(name, starts, hashes)
        size_field = "#{name}|#{QueueRollup::SIZE_KIND}"
        lat_field  = "#{name}|#{QueueRollup::LAT_KIND}"
        starts.zip(hashes).map do |at, hash|
          { at: at, size: hash[size_field].to_i, latency: (hash[lat_field] || 0).to_f }
        end
      end

      def bucket_spec!(bucket)
        Rollup::BUCKETS.fetch(bucket) do
          raise ArgumentError, "bucket must be one of #{Rollup::BUCKETS.keys.inspect}"
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
        check_window!(Integer(minutes), Query::MAX_MINUTES, 'minutes')
      end

      def cap_hours!(hours)
        check_window!(Integer(hours), Query::MAX_HOURS, 'hours')
      end

      def check_window!(value, max, label)
        raise ArgumentError, "#{label} must be positive" if value <= 0
        raise Query::WindowTooWide, "#{label} must be <= #{max} (got #{value})" if value > max

        value
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
