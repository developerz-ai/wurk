# frozen_string_literal: true

require 'time'
require_relative '../deploy'
require_relative '../pool_checkout'
require_relative 'history'
require_relative 'histogram'
require_relative 'dashboard_series'

module Wurk
  module Metrics
    # Read side of the per-class buckets Wurk::Metrics::History writes.
    #
    # The instance API is Sidekiq's `Sidekiq::Metrics::Query` (spec
    # docs/target/sidekiq-free.md §20): `Query.new(now:).top_jobs` /
    # `#for_job` return a `Result` whose `job_results[klass]` is a `JobResult`
    # with `totals` / `series` / `hist`. Window caps clamp silently, as upstream.
    #
    # The class-level functions (Metrics::DashboardSeries) back Wurk's
    # dashboard JSON API.
    class Query
      MAX_MINUTES = 480
      MAX_HOURS = 72
      MAX_QUEUE_SERIES = 25

      class WindowTooWide < ::ArgumentError; end

      extend DashboardSeries

      ROLLUPS = {
        minutely: [60, ->(time) { History.minute_key(time) }],
        hourly: [600, ->(time) { History.ten_minute_key(time) }]
      }.freeze

      def self.bkt_time_s(time, granularity)
        truncation = granularity == :hourly ? 600 : 60
        ::Time.at(time.to_i - (time.to_i % truncation)).utc.iso8601
      end

      def initialize(pool: nil, now: ::Time.now)
        @time = now.utc
        @pool = pool
      end

      # `class_filter` is matched with `class_filter.match?(klass)`, so pass a
      # Regexp, as Sidekiq's Web UI does.
      def top_jobs(class_filter: nil, minutes: nil, hours: nil)
        result, keys = window(minutes, hours)
        rows = pipelined(keys) { |pipe, key| pipe.call('HGETALL', key) }
        each_bucket(result, rows) { |time, hash| add_bucket(result, time, hash_reply(hash), class_filter) }
        finish(result)
      end

      FOR_JOB_METRICS = %w[ms p f].freeze

      def for_job(klass, minutes: nil, hours: nil)
        result, keys = window(minutes, hours)
        fields = FOR_JOB_METRICS.map { |metric| "#{klass}|#{metric}" }
        job = result.job_results[klass]
        each_bucket(result, pipelined(keys) { |pipe, key| pipe.call('HMGET', key, *fields) }) do |time, values|
          add_job_bucket(job, time, values)
        end
        add_histograms(job, klass, keys.size) if result.granularity == :minutely
        finish(result)
      end

      # `size` is a member name of upstream's struct, so it stays.
      Result = Struct.new(:granularity, :starts_at, :ends_at, :size, :job_results, :marks) do # rubocop:disable Lint/StructNewOverride
        def initialize(granularity = :minutely)
          super
          self.granularity = granularity
          self.marks = []
          self.job_results = ::Hash.new { |h, k| h[k] = JobResult.new(granularity) }
        end
      end

      JobResult = Struct.new(:granularity, :series, :hist, :totals) do
        def initialize(granularity = :minutely)
          super
          self.granularity = granularity
          self.series = ::Hash.new { |h, k| h[k] = ::Hash.new(0) }
          self.hist = ::Hash.new { |h, k| h[k] = [] }
          self.totals = ::Hash.new(0)
        end

        # An `ms` sample also books the same time in seconds under `s`.
        def add_metric(metric, time, value)
          totals[metric] += value
          series[metric][Query.bkt_time_s(time, granularity)] += value
          add_metric('s', time, value / 1000.0) if metric == 'ms'
        end

        def add_hist(time, hist_result)
          hist[Query.bkt_time_s(time, granularity)] = hist_result
        end

        # Per successful execution: `p` counts failures too.
        def total_avg(metric = 'ms')
          completed = totals['p'] - totals['f']
          return 0 if completed.zero?

          totals[metric].to_f / completed
        end

        def series_avg(metric = 'ms')
          series[metric].each_with_object(::Hash.new(0)) do |(bucket, value), out|
            completed = series.dig('p', bucket) - series.dig('f', bucket)
            out[bucket] = completed.zero? ? 0 : value.to_f / completed
          end
        end
      end

      MarkResult = Struct.new(:time, :label, :bucket)

      private

      # Bucket keys newest first, starting at `now`, plus the Result they fill.
      def window(minutes, hours)
        minutes, hours = clamp(minutes, hours)
        granularity = hours ? :hourly : :minutely
        stride, keyproc = ROLLUPS.fetch(granularity)
        count = hours ? hours * 6 : minutes

        result = Result.new(granularity)
        result.ends_at = @time
        result.starts_at = @time - (count * stride)
        [result, Array.new(count) { |i| keyproc.call(@time - (i * stride)) }]
      end

      # Upstream's DoS caps: an oversized minute window falls back to the
      # 60-minute default, an oversized hour window to the 72h ceiling.
      def clamp(minutes, hours)
        minutes = 60 unless minutes || hours
        minutes = 60 if minutes && minutes > MAX_MINUTES
        [minutes, hours && [hours, MAX_HOURS].min]
      end

      def add_bucket(result, time, hash, class_filter)
        hash.each do |field, value|
          kls, metric = field.split('|', 2)
          next if metric.nil? || (class_filter && !class_filter.match?(kls))

          result.job_results[kls].add_metric(metric, time, value.to_i)
        end
      end

      def add_job_bucket(job, time, values)
        FOR_JOB_METRICS.zip(values).each { |metric, value| job.add_metric(metric, time, value.to_i) if value }
      end

      def pipelined(keys)
        with_redis { |c| c.pipelined { |pipe| keys.each { |key| yield pipe, key } } }
      end

      def each_bucket(result, rows)
        stride, = ROLLUPS.fetch(result.granularity)
        rows.each_with_index { |row, i| yield @time - (i * stride), row }
      end

      def add_histograms(job, klass, count)
        times = Array.new(count) { |i| @time - (i * 60) }
        counts = pipelined(times) { |pipe, t| pipe.call('BITFIELD_RO', Histogram.key(klass, t), *Histogram::FETCH) }
        times.zip(counts).each { |t, raw| job.add_hist(t, raw.map(&:to_i).reverse) }
      end

      def finish(result)
        result.marks = fetch_marks(result.starts_at..result.ends_at, result.granularity)
        result
      end

      def fetch_marks(range, granularity)
        Deploy.new(pool: @pool).fetch(@time).filter_map do |stamp, label|
          time = ::Time.parse(stamp)
          MarkResult.new(time, label, Query.bkt_time_s(time, granularity)) if range.cover?(time)
        end
      end

      def hash_reply(raw)
        raw.is_a?(::Array) ? raw.each_slice(2).to_h : (raw || {})
      end

      def with_redis(&)
        @pool ? PoolCheckout.with(@pool, true, &) : Wurk.redis(idempotent: true, &)
      end
    end
  end
end
