# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Parity oracle for the execution-metrics read API and the bucket keys it
# reads — `Sidekiq::Metrics::Query` with its `Result` / `JobResult` /
# `MarkResult` structs, and the `j|…` per-class HASH buckets.
#
# Spec: docs/target/sidekiq-free.md §20 (Query, ROLLUPS key procs
# `j|%y%m%d|%-H:%M` and `j|%y%m%d|%-H:<minute tens digit>`, DoS caps) and §1.6
# (bucket fields `<klass>|p`, `|f`, `|ms`; deploy marks `<YYYYMMDD>-marks`).
# Buckets are seeded exactly as a Sidekiq process writes them, so a drop-in
# swap reads pre-existing history.
class MetricsQueryParityTest < Wurk::Test::UnitCase
  parallelize_me!

  NOW = ::Time.utc(2025, 2, 14, 8, 43, 20)

  def setup
    super
    @klass = "ParityMetricsJob#{SecureRandom.hex(6)}"
  end

  def test_minutely_buckets_feed_top_jobs_totals
    seed('j|250214|8:43', 'p' => 3, 'f' => 1, 'ms' => 600)
    seed('j|250214|8:42', 'p' => 2, 'ms' => 100)
    seed('j|250214|8:05', 'p' => 50) # outside a 5-minute window

    result = Sidekiq::Metrics::Query.new(now: NOW).top_jobs(minutes: 5)
    job = result.job_results[@klass]

    assert_instance_of Sidekiq::Metrics::Query::Result, result
    assert_instance_of Sidekiq::Metrics::Query::JobResult, job
    assert_equal 5, job.totals['p']
    assert_equal 1, job.totals['f']
    assert_equal 700, job.totals['ms']
    assert_in_delta 0.7, job.totals['s']
    assert_equal :minutely, result.granularity
    assert_equal NOW, result.ends_at
  end

  # `average = ms / (p - f)`: `p` counts failed executions too.
  def test_averages_divide_by_completed_executions
    seed('j|250214|8:43', 'p' => 5, 'f' => 1, 'ms' => 400)

    job = Sidekiq::Metrics::Query.new(now: NOW).top_jobs(minutes: 1).job_results[@klass]

    assert_in_delta 100.0, job.total_avg('ms')
    assert_equal({ '2025-02-14T08:43:00Z' => 100.0 }, job.series_avg('ms'))
  end

  def test_hourly_reads_ten_minute_buckets
    seed('j|250214|8:4', 'p' => 7)
    seed('j|250214|8:3', 'p' => 4)

    result = Sidekiq::Metrics::Query.new(now: NOW).top_jobs(hours: 1)
    job = result.job_results[@klass]

    assert_equal :hourly, result.granularity
    assert_equal 11, job.totals['p']
    assert_equal 7, job.series['p']['2025-02-14T08:40:00Z']
  end

  def test_for_job_reads_one_class
    seed('j|250214|8:43', 'p' => 2, 'ms' => 50)

    result = Sidekiq::Metrics::Query.new(now: NOW).for_job(@klass, minutes: 3)

    assert_equal [@klass], result.job_results.keys
    assert_equal 2, result.job_results[@klass].totals['p']
  end

  def test_window_caps
    query = Sidekiq::Metrics::Query.new(now: NOW)

    assert_operator query.top_jobs(minutes: 10_000).starts_at, :>=, NOW - (480 * 60)
    assert_operator query.top_jobs(hours: 10_000).starts_at, :>=, NOW - (72 * 3600)
  end

  def test_marks_come_from_the_day_marks_hash
    Wurk.redis { |c| c.call('HSET', '20250214-marks', '2025-02-14T08:40:00Z', "deploy #{@klass}") }

    marks = Sidekiq::Metrics::Query.new(now: NOW).top_jobs(minutes: 10).marks
    mark = marks.find { |m| m.label == "deploy #{@klass}" }

    assert_instance_of Sidekiq::Metrics::Query::MarkResult, mark
    assert_equal ::Time.utc(2025, 2, 14, 8, 40), mark.time
    assert_equal '2025-02-14T08:40:00Z', mark.bucket
  end

  # A job Wurk executes lands in the bucket Sidekiq's own Query reads: the
  # current UTC minute under `j|%y%m%d|%-H:%M`. (Wurk batches the writes;
  # the flush stands in for its periodic flusher.)
  def test_executed_jobs_land_in_the_spec_minute_key
    before = ::Time.now.utc
    Wurk.configuration.default_capsule.server_middleware.invoke(nil, { 'class' => @klass }, 'default') { :ok }
    Wurk::Metrics::History.flush
    after = ::Time.now.utc

    keys = [before, after].map { |t| t.strftime('j|%y%m%d|%-H:%M') }.uniq
    counts = Wurk.redis { |c| keys.map { |k| c.call('HGET', k, "#{@klass}|p") } }

    assert_equal 1, counts.compact.sum(&:to_i)
    totals = Sidekiq::Metrics::Query.new(now: after).top_jobs(minutes: 2).job_results[@klass].totals

    assert_equal 1, totals['p']
  end

  private

  def seed(key, fields)
    Wurk.redis { |c| c.call('HSET', key, *fields.flat_map { |metric, v| ["#{@klass}|#{metric}", v] }) }
  end
end
