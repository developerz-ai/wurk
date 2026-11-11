# frozen_string_literal: true

require 'time'
require_relative 'sampler'

module WurkSoak
  # Turns the run's samples and ledger verdict into the JSON artifact and the
  # printed summary. Slopes are per minute and advisory: a child replaced by
  # chaos has a short series, so only children sampled at least MIN_POINTS
  # times get a slope of their own.
  class Report
    MIN_POINTS = 3

    def initialize(opts:, verdict:, samples:, drained:)
      @opts = opts
      @verdict = verdict
      @samples = samples
      @drained = drained
    end

    def to_h
      { generated_at: Time.now.utc.iso8601, ruby: RUBY_VERSION, wurk: Wurk::VERSION, options: @opts,
        drained: @drained, verdict: @verdict, slopes: slopes, last_sample: @samples.last, samples: @samples }
    end

    def slopes
      { child_pss_kb_per_min: child_slopes, fleet_pss_kb_per_min: per_min(fleet_pss),
        redis_keys_per_min: per_min(redis_series(:dbsize)),
        redis_used_memory_bytes_per_min: per_min(redis_series(:used_memory)) }
    end

    def self.summary(report)
      v = report[:verdict]
      s = report[:slopes]
      [
        "soak verdict: #{v[:balanced] ? 'BALANCED' : 'NOT BALANCED'} (drained=#{report[:drained]})",
        "  pushed #{v[:pushed]}  completed #{v[:completed]}  lost #{v[:lost].size}  dead #{v[:dead].size}  " \
        "reruns #{v[:reruns]}  unledgered #{v[:unledgered].size}",
        "  duplicates: #{v[:duplicates][:by_window].transform_values { |w| w[:count] }}  " \
        "unattributed #{v[:duplicates][:unattributed].size}",
        "  batches: #{v[:batches].except(:missing, :out_of_order)} missing #{v[:batches][:missing].size} " \
        "out_of_order #{v[:batches][:out_of_order].size}",
        "  cron #{v[:cron]}  unique #{v[:unique]}  push_errors #{v[:push_errors]}  lossy_drops #{v[:lossy_drops]}",
        "  chaos #{v[:chaos]}",
        "  slopes/min: child PSS kB #{s[:child_pss_kb_per_min]}  fleet PSS kB #{s[:fleet_pss_kb_per_min]}  " \
        "redis keys #{s[:redis_keys_per_min]}  redis bytes #{s[:redis_used_memory_bytes_per_min]}"
      ].join("\n")
    end

    private

    def child_slopes
      series = Hash.new { |h, k| h[k] = [] }
      @samples.each { |s| s[:children].each { |pid, mem| series[pid] << [s[:t], mem[:pss]] } }
      rates = series.values.select { |pts| pts.size >= MIN_POINTS }.filter_map { |pts| per_min(pts) }.sort
      return { children: 0 } if rates.empty?

      { children: rates.size, median: rates[rates.size / 2], max: rates.last, min: rates.first }
    end

    def fleet_pss = @samples.map { |s| [s[:t], s[:children].values.sum { |m| m[:pss] }] }

    def redis_series(key) = @samples.filter_map { |s| s[:redis] && [s[:t], s[:redis][key]] }

    def per_min(points)
      rate = Sampler.slope(points)
      rate && (rate * 60).round(2)
    end
  end
end
