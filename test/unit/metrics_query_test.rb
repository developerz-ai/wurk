# frozen_string_literal: true

require_relative '../test_helper'

class MetricsQueryTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @suffix = "q#{Process.pid}_#{object_id}"
    @klass_a = "AlphaJob#{@suffix}"
    @klass_b = "BetaJob#{@suffix}"
    # Pin the test window to a stable UTC moment, well past minute boundary
    # so floor_to(:min) lands inside our writes (not on the second-edge).
    @now = ::Time.utc(2026, 5, 21, 14, 37, 12)
  end

  def teardown
    Wurk.redis do |c|
      cursor = '0'
      loop do
        cursor, keys = c.call('SCAN', cursor, 'MATCH', "*#{@suffix}*", 'COUNT', 500)
        c.call('DEL', *keys) unless keys.empty?
        break if cursor == '0'
      end
      delete_class_fields(c)
      # The queue_history tests SADD this suite's queues to the shared `queues`
      # set; remove them so queue_history(queues: nil) can't read a leftover.
      mine = c.call('SMEMBERS', 'queues').select { |q| q.include?(@suffix) }
      c.call('SREM', 'queues', *mine) unless mine.empty?
    end
  ensure
    super
  end

  # Per-class fields only — never DEL the shared minute buckets, or other
  # parallel tests for the same minute will lose their writes.
  def delete_class_fields(conn)
    [@now, @now - 60, @now - 120, @now - 180, @now - 240, @now - 300, @now - 360, @now - 420].each do |t|
      key = Wurk::Metrics::History.minute_key(t)
      [@klass_a, @klass_b].each do |kls|
        conn.call('HDEL', key, "#{kls}|p", "#{kls}|f", "#{kls}|ms", "#{kls}|x", "#{kls}nodelim")
      end
    end
  end

  # ---- caps ---------------------------------------------------------------

  def test_top_jobs_caps_minutes
    assert_raises(Wurk::Metrics::Query::WindowTooWide) do
      Wurk::Metrics::Query.top_jobs(minutes: 481)
    end
  end

  def test_top_jobs_caps_hours
    assert_raises(Wurk::Metrics::Query::WindowTooWide) do
      Wurk::Metrics::Query.top_jobs(hours: 73)
    end
  end

  def test_top_jobs_requires_positive_minutes
    assert_raises(ArgumentError) do
      Wurk::Metrics::Query.top_jobs(minutes: 0)
    end
  end

  def test_for_job_requires_class
    assert_raises(ArgumentError) do
      Wurk::Metrics::Query.for_job(nil, minutes: 1)
    end
  end

  def test_for_job_rejects_both_minutes_and_hours
    assert_raises(ArgumentError) do
      Wurk::Metrics::Query.for_job('X', minutes: 1, hours: 1)
    end
  end

  def test_for_job_rejects_neither_minutes_nor_hours
    assert_raises(ArgumentError) do
      Wurk::Metrics::Query.for_job('X')
    end
  end

  def test_for_job_caps_minutes
    assert_raises(Wurk::Metrics::Query::WindowTooWide) do
      Wurk::Metrics::Query.for_job('X', minutes: 999)
    end
  end

  def test_for_job_caps_hours
    assert_raises(Wurk::Metrics::Query::WindowTooWide) do
      Wurk::Metrics::Query.for_job('X', hours: 999)
    end
  end

  # ---- top_jobs aggregation -----------------------------------------------

  def test_top_jobs_aggregates_per_class
    Wurk::Metrics::History.record(@klass_a, 100, success: true, at: @now)
    Wurk::Metrics::History.record(@klass_a, 200, success: false, at: @now - 60)
    Wurk::Metrics::History.record(@klass_b, 50, success: true, at: @now)

    rows = Wurk::Metrics::Query.top_jobs(minutes: 5, now: @now)
    found = rows.to_h

    assert_equal({ p: 1, f: 1, ms: 300 }, found[@klass_a])
    assert_equal({ p: 1, f: 0, ms: 50 }, found[@klass_b])
  end

  # Regression (#metrics-double-count): before the fix, a job at minute x1..x9
  # was also written into that decade's x0 key (the old 10-min rollup), so a
  # window spanning the x0 minute summed each job twice. @now is 14:37; these
  # three land at 14:31/32/33 (all in decade 14:30), and a 10-minute window
  # reaches back over 14:30. The total must be 3, not 6.
  def test_top_jobs_does_not_double_count_across_the_rollup_boundary
    [31, 32, 33].each do |m|
      Wurk::Metrics::History.record(@klass_a, 100, success: true, at: ::Time.utc(2026, 5, 21, 14, m, 0))
    end

    found = Wurk::Metrics::Query.top_jobs(minutes: 10, now: @now).to_h

    assert_equal({ p: 3, f: 0, ms: 300 }, found[@klass_a])
  end

  def test_top_jobs_sorted_descending_by_volume
    5.times { Wurk::Metrics::History.record(@klass_a, 1, success: true, at: @now) }
    2.times { Wurk::Metrics::History.record(@klass_b, 1, success: true, at: @now) }

    rows = Wurk::Metrics::Query.top_jobs(minutes: 5, now: @now)
    classes = rows.map(&:first).select { |k| [@klass_a, @klass_b].include?(k) }

    assert_equal [@klass_a, @klass_b], classes
  end

  def test_top_jobs_filters_by_prefix
    Wurk::Metrics::History.record(@klass_a, 1, success: true, at: @now)
    Wurk::Metrics::History.record(@klass_b, 1, success: true, at: @now)

    rows = Wurk::Metrics::Query.top_jobs(class_filter: 'Alpha', minutes: 5, now: @now)
    klasses = rows.map(&:first)

    assert(klasses.all? { |k| k.start_with?('Alpha') })
    assert_includes klasses, @klass_a
  end

  def test_top_jobs_hours_arg_converts_to_minutes
    Wurk::Metrics::History.record(@klass_a, 7, success: true, at: @now)

    rows = Wurk::Metrics::Query.top_jobs(hours: 1, now: @now)

    assert_includes rows.map(&:first), @klass_a
  end

  # ---- for_job series -----------------------------------------------------

  def test_for_job_minutes_returns_chronological_rows
    Wurk::Metrics::History.record(@klass_a, 10, success: true, at: @now - 60)
    Wurk::Metrics::History.record(@klass_a, 25, success: true, at: @now)

    rows = Wurk::Metrics::Query.for_job(@klass_a, minutes: 3, now: @now)

    assert_equal 3, rows.size
    assert_operator rows.first[:at], :<, rows.last[:at]
    last_two = rows.last(2).map { |r| r[:p] }

    assert_equal [1, 1], last_two
  end

  def test_for_job_minutes_returns_zeros_for_empty_buckets
    rows = Wurk::Metrics::Query.for_job(@klass_a, minutes: 2, now: @now)

    assert(rows.all? { |r| r[:p].zero? && r[:f].zero? && r[:ms].zero? })
  end

  def test_for_job_hours_returns_chronological_rows
    Wurk::Metrics::History.record(@klass_a, 99, success: true, at: @now)

    rows = Wurk::Metrics::Query.for_job(@klass_a, hours: 2, now: @now)

    assert_equal 2, rows.size
    assert_equal 1, rows.last[:p]
    assert_equal 99, rows.last[:ms]
  end

  # ---- history window guard (line 70 then) --------------------------------

  def test_history_rejects_non_positive_window
    assert_raises(ArgumentError) do
      Wurk::Metrics::Query.history('1m', 0, now: @now)
    end
    assert_raises(ArgumentError) do
      Wurk::Metrics::Query.history('1m', -60, now: @now)
    end
  end

  # ---- accumulate! field skipping (line 114 then) -------------------------

  def test_top_jobs_skips_fields_without_kind_or_unknown_kind
    key = Wurk::Metrics::History.minute_key(@now)
    Wurk.redis do |c|
      # Real per-class counters the query must still sum.
      c.call('HSET', key, "#{@klass_a}|p", 3, "#{@klass_a}|ms", 120)
      # Field with no '|' delimiter → split returns [field, nil] → kind nil.
      c.call('HSET', key, "#{@klass_a}nodelim", 99)
      # Field with a kind not in TOTAL_FIELDS (p/f/ms) → skipped.
      c.call('HSET', key, "#{@klass_a}|x", 99)
    end

    rows = Wurk::Metrics::Query.top_jobs(minutes: 1, now: @now)
    found = rows.to_h

    # Only the recognized p/ms fields counted; bogus fields ignored.
    assert_equal({ p: 3, f: 0, ms: 120 }, found[@klass_a])
    # The malformed bare field is treated as its own class with no kind, so
    # it must never surface as a row.
    refute_includes found.keys, "#{@klass_a}nodelim"
  end

  # ---- floor_to :hour branch (line 154) -----------------------------------

  def test_floor_to_hour_truncates_to_hour_boundary
    floored = Wurk::Metrics::Query.floor_to(@now, :hour)

    assert_equal ::Time.utc(2026, 5, 21, 14), floored
    assert_equal 0, floored.min
    assert_equal 0, floored.sec
  end

  # The case/when in floor_to has an implicit else (unit neither :min nor
  # :hour) that returns nil. Unreachable through the public API — only :min
  # and :hour are ever passed internally — but floor_to is a module_function,
  # so we exercise the no-match fall-through directly for branch coverage.
  def test_floor_to_unknown_unit_returns_nil
    assert_nil Wurk::Metrics::Query.floor_to(@now, :day)
  end

  # ---- empty-key pipeline short-circuits (lines 161, 167 then) ------------

  def test_pipeline_hgetall_empty_keys_returns_empty
    assert_equal [], Wurk::Metrics::Query.pipeline_hgetall([])
  end

  def test_pipeline_hmget_empty_keys_returns_empty
    assert_equal [], Wurk::Metrics::Query.pipeline_hmget([], %w[p f ms])
  end

  # ---- queue_history reader (per-queue size/latency gauges) ----------------

  def test_queue_history_returns_per_queue_size_and_latency_series
    q1 = "Qa#{@suffix}"
    q2 = "Qb#{@suffix}"
    write_qm('1m', @now, "#{q1}|sz" => 5, "#{q1}|lt" => 12.5, "#{q2}|sz" => 2, "#{q2}|lt" => 0)

    series = Wurk::Metrics::Query.queue_history('1m', 300, queues: [q1, q2], now: @now)
    points = series.find { |s| s[:name] == q1 }[:points]

    assert_equal 5, points.size # window 300 / 60 = 5 points, gap-filled
    assert_equal({ at: (@now.to_i / 60) * 60, size: 5, latency: 12.5 }, points.last)
  end

  def test_queue_history_gap_fills_missing_buckets_with_zeros
    series = Wurk::Metrics::Query.queue_history('1m', 300, queues: ["Qz#{@suffix}"], now: @now)
    points = series.first[:points]

    assert_equal 5, points.size
    assert(points.all? { |p| p[:size].zero? && p[:latency].zero? })
  end

  def test_queue_history_returns_empty_when_no_queues
    assert_equal [], Wurk::Metrics::Query.queue_history('1m', 300, queues: [], now: @now)
  end

  def test_queue_history_rejects_unknown_bucket
    assert_raises(ArgumentError) { Wurk::Metrics::Query.queue_history('2m', 300, queues: ['x'], now: @now) }
  end

  def test_queue_history_clamps_window_to_bucket_retention
    series = Wurk::Metrics::Query.queue_history('1m', 48 * 3600, queues: ["Qc#{@suffix}"], now: @now)

    assert_operator series.first[:points].size, :<=, 24 * 60
  end

  def test_queue_history_reads_live_queue_set_when_queues_nil
    q1 = "Qlive#{@suffix}"
    Wurk.redis { |c| c.call('SADD', 'queues', q1) }
    write_qm('1m', @now, "#{q1}|sz" => 7, "#{q1}|lt" => 3.0)

    series = Wurk::Metrics::Query.queue_history('1m', 120, now: @now)
    row = series.find { |s| s[:name] == q1 }

    refute_nil row, 'queue from the live `queues` set should be charted'
    assert_equal 7, row[:points].last[:size]
  end

  def test_queue_history_caps_queue_count
    names = (0...30).map { |i| format('Qcap%<s>s_%<i>02d', s: @suffix, i: i) }
    Wurk.redis { |c| c.call('SADD', 'queues', *names) }

    series = Wurk::Metrics::Query.queue_history('1m', 120, now: @now)

    assert_operator series.size, :<=, Wurk::Metrics::Query::MAX_QUEUE_SERIES
  end

  private

  # Write a per-queue gauge bucket directly so the reader tests don't depend on
  # the sampler's wall-clock latency math.
  def write_qm(bucket, at, fields)
    step = Wurk::Metrics::QueueRollup::BUCKETS[bucket][0]
    key = Wurk::Metrics::QueueRollup.bucket_key(bucket, (at.to_i / step) * step)
    Wurk.redis { |c| c.call('HSET', key, *fields.flatten) }
  end
end
