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
      # Per-class fields only — never DEL the shared minute/rollup buckets,
      # other parallel tests for the same minute will lose their writes.
      [@now, @now - 60, @now - 120].each do |t|
        [Wurk::Metrics::History.minute_key(t), Wurk::Metrics::History.rollup_key(t)].each do |key|
          [@klass_a, @klass_b].each do |kls|
            c.call('HDEL', key, "#{kls}|p", "#{kls}|f", "#{kls}|ms", "#{kls}|x", "#{kls}nodelim")
          end
        end
      end
    end
  ensure
    super
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
end
