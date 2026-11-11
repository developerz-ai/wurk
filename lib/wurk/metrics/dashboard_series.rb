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
      TOTAL_KINDS = { 'p' => :p, 'f' => :f, 'ms' => :ms }.freeze
      NO_FIELD = [nil, nil].freeze

      # Buckets per pipelined read in #top_jobs. A 30-day window is 4320
      # buckets of every class's fields; reading and folding a day at a time
      # keeps one day's replies in memory instead of the whole month's.
      TOP_JOBS_SLICE = 144

      # Dashboard top-N: `[[klass, {p:, f:, ms:}], …]` over the window,
      # busiest (`p`, which counts failures) first. `class_filter` is a
      # class-name prefix. Sums straight off the buckets rather than through
      # Query#top_jobs, whose per-bucket series a table never shows.
      def top_jobs(class_filter: nil, minutes: 60, hours: nil, now: ::Time.now)
        _stamps, keys = window_buckets(minutes, hours, now)
        rows = sum_totals(keys).to_a
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

        rows = queue_bucket_rows(bucket, starts, names)
        names.each_with_index.map { |name, i| { name: name, points: queue_points(i, starts, rows) } }
      end

      private

      # Bucket start times oldest→newest and their keys: one per minute for
      # `minutes`, one per 10 minutes for `hours` (which wins when both given).
      def window_buckets(minutes, hours, now)
        minutes, buckets = promote_minute_window(minutes, hours)
        stride, keyproc = Query::ROLLUPS.fetch(buckets ? :hourly : :minutely)
        count = buckets || cap_minutes!(minutes)
        stamps = bucket_starts(now, stride, count * stride).map { |s| ::Time.at(s).utc }
        [stamps, stamps.map(&keyproc)]
      end

      # 10-minute bucket counts for the requested window — nil stays on the
      # per-minute buckets. An explicit `hours:` is six buckets per hour
      # (cap_hours! still bounds it). A minute window past MAX_MINUTES
      # promotes onto the 10-minute buckets (whose 30-day retention covers
      # it) instead of raising; it still WindowTooWides past MAX_HOURS * 60
      # minutes — checked in minutes first so the error names the unit the
      # caller passed. The promoted window is counted in 10-minute buckets,
      # ceil(minutes / 10), not rounded up to whole hours (#726): 490 minutes
      # is 49 buckets, not 9 hours' 54, so the totals never reach past the
      # window the caller asked for by more than the trailing partial bucket.
      def promote_minute_window(minutes, hours)
        return [minutes, cap_hours!(hours) * 6] unless hours.nil?
        return [minutes, nil] unless minutes && minutes > Query::MAX_MINUTES

        checked = check_window!(Integer(minutes), Query::MAX_HOURS * 60, 'minutes')
        [nil, (checked / 10.0).ceil]
      end

      # Every bucket repeats the same few hundred `<klass>|<kind>` fields, so
      # each distinct field is split once per call, not once per bucket.
      def sum_totals(keys)
        totals = ::Hash.new { |h, k| h[k] = { p: 0, f: 0, ms: 0 } }
        parsed = ::Hash.new { |h, field| h[field] = parse_total_field(field) }
        keys.each_slice(TOP_JOBS_SLICE) do |slice|
          pipeline_hgetall(slice).each { |raw| fold_totals(totals, parsed, hash_reply(raw)) }
        end
        totals
      end

      def fold_totals(totals, parsed, hash)
        hash.each do |field, value|
          klass, kind = parsed[field]
          totals[klass][kind] += value.to_i if kind
        end
      end

      def parse_total_field(field)
        klass, kind = field.split('|', 2)
        kind = TOTAL_KINDS[kind]
        kind ? [klass, kind] : NO_FIELD
      end

      def hash_reply(raw)
        raw.is_a?(::Array) ? raw.each_slice(2).to_h : (raw || {})
      end

      def pfms_rows(stamps, rows)
        stamps.zip(rows).map { |at, (p, f, ms)| { at: at, p: p.to_i, f: f.to_i, ms: ms.to_i } }
      end

      # Only the requested queues' two fields per bucket, not every queue's: a
      # bucket holds a pair per live queue, and a series names at most
      # MAX_QUEUE_SERIES of them.
      def queue_bucket_rows(bucket, starts, names)
        fields = names.flat_map { |name| ["#{name}|#{QueueRollup::SIZE_KIND}", "#{name}|#{QueueRollup::LAT_KIND}"] }
        pipeline_hmget(starts.map { |s| QueueRollup.bucket_key(bucket, s) }, fields)
      end

      def queue_names(queues)
        names = queues || Wurk.redis { |c| c.call('SMEMBERS', Wurk::Keys::QUEUES_SET) }
        names.sort.first(Query::MAX_QUEUE_SERIES)
      end

      def queue_points(index, starts, rows)
        starts.zip(rows).map do |at, row|
          { at: at, size: row[index * 2].to_i, latency: (row[(index * 2) + 1] || 0).to_f }
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
