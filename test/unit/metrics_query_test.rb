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

  # Wurk::Metrics::Query is Sidekiq::Metrics::Query (compat aliases the module).
  def query(**) = Sidekiq::Metrics::Query.new(now: @now, **)

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
    times = [@now, @now - 60, @now - 120, @now - 180, @now - 240, @now - 300, @now - 360, @now - 420]
    keys = times.flat_map { |t| [Wurk::Metrics::History.minute_key(t), Wurk::Metrics::History.ten_minute_key(t)] }
    keys.uniq.each do |key|
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
    Wurk::Metrics::History.flush

    rows = Wurk::Metrics::Query.top_jobs(minutes: 5, now: @now)
    found = rows.to_h

    assert_equal({ p: 2, f: 1, ms: 100 }, found[@klass_a])
    assert_equal({ p: 1, f: 0, ms: 50 }, found[@klass_b])
  end

  # Regression (#metrics-double-count): a minute window must never read the
  # 10-minute bucket. @now is 14:37; these three land at 14:31/32/33 (all in
  # 10-minute bucket `14:3`), and a 10-minute window reaches back over 14:30.
  # The total must be 3, not 6.
  def test_top_jobs_does_not_double_count_across_the_rollup_boundary
    [31, 32, 33].each do |m|
      Wurk::Metrics::History.record(@klass_a, 100, success: true, at: ::Time.utc(2026, 5, 21, 14, m, 0))
    end
    Wurk::Metrics::History.flush

    found = Wurk::Metrics::Query.top_jobs(minutes: 10, now: @now).to_h

    assert_equal({ p: 3, f: 0, ms: 300 }, found[@klass_a])
  end

  def test_top_jobs_sorted_descending_by_volume
    5.times { Wurk::Metrics::History.record(@klass_a, 1, success: true, at: @now) }
    2.times { Wurk::Metrics::History.record(@klass_b, 1, success: true, at: @now) }
    Wurk::Metrics::History.flush

    rows = Wurk::Metrics::Query.top_jobs(minutes: 5, now: @now)
    classes = rows.map(&:first).select { |k| [@klass_a, @klass_b].include?(k) }

    assert_equal [@klass_a, @klass_b], classes
  end

  def test_top_jobs_filters_by_prefix
    Wurk::Metrics::History.record(@klass_a, 1, success: true, at: @now)
    Wurk::Metrics::History.record(@klass_b, 1, success: true, at: @now)
    Wurk::Metrics::History.flush

    rows = Wurk::Metrics::Query.top_jobs(class_filter: 'Alpha', minutes: 5, now: @now)
    klasses = rows.map(&:first)

    assert(klasses.all? { |k| k.start_with?('Alpha') })
    assert_includes klasses, @klass_a
  end

  # Regression: `hours:` used to be re-validated against MAX_MINUTES after the
  # ×60 conversion, so anything above 8h raised WindowTooWide and the
  # documented 72h ceiling was unreachable. The minute buckets it reads live
  # for MID_TERM (3 days), so the whole range is backed by data.
  def test_top_jobs_hours_reaches_the_documented_ceiling
    Wurk::Metrics::History.record(@klass_a, 5, success: true, at: @now)
    Wurk::Metrics::History.flush

    [9, Wurk::Metrics::Query::MAX_HOURS].each do |hours|
      rows = Wurk::Metrics::Query.top_jobs(hours: hours, now: @now)

      assert_includes rows.map(&:first), @klass_a, "hours: #{hours}"
    end
  end

  def test_top_jobs_hours_arg_converts_to_minutes
    Wurk::Metrics::History.record(@klass_a, 7, success: true, at: @now)
    Wurk::Metrics::History.flush

    rows = Wurk::Metrics::Query.top_jobs(hours: 1, now: @now)

    assert_includes rows.map(&:first), @klass_a
  end

  # ---- for_job series -----------------------------------------------------

  def test_for_job_minutes_returns_chronological_rows
    Wurk::Metrics::History.record(@klass_a, 10, success: true, at: @now - 60)
    Wurk::Metrics::History.record(@klass_a, 25, success: true, at: @now)
    Wurk::Metrics::History.flush

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
    Wurk::Metrics::History.flush

    rows = Wurk::Metrics::Query.for_job(@klass_a, hours: 2, now: @now)

    assert_equal 12, rows.size, 'one row per 10-minute bucket'
    assert_equal ::Time.utc(2026, 5, 21, 14, 30), rows.last[:at]
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

  # ---- spec-shaped instance API (§20) ------------------------------------

  def test_new_top_jobs_returns_a_result_keyed_by_class
    Wurk::Metrics::History.record(@klass_a, 100, success: true, at: @now)
    Wurk::Metrics::History.record(@klass_a, 300, success: false, at: @now - 60)
    Wurk::Metrics::History.flush

    result = query.top_jobs(minutes: 5)
    job = result.job_results[@klass_a]

    assert_kind_of Sidekiq::Metrics::Query::Result, result
    assert_kind_of Sidekiq::Metrics::Query::JobResult, job
    assert_equal :minutely, result.granularity
    assert_equal [@now, @now - 300], [result.ends_at, result.starts_at]
    assert_equal [2, 1, 100, 0.1], job.totals.values_at('p', 'f', 'ms', 's')
    assert_equal 1, job.series['p']['2026-05-21T14:37:00Z']
    assert_in_delta 100.0, job.total_avg
  end

  def test_new_top_jobs_filters_with_a_regexp
    Wurk::Metrics::History.record(@klass_a, 1, success: true, at: @now)
    Wurk::Metrics::History.record(@klass_b, 1, success: true, at: @now)
    Wurk::Metrics::History.flush

    keys = query.top_jobs(class_filter: /\AAlpha/, minutes: 1).job_results.keys

    assert_includes keys, @klass_a
    refute_includes keys, @klass_b
  end

  # Upstream clamps silently: minutes > 480 falls back to 60, hours to 72.
  def test_new_clamps_windows_like_upstream
    assert_equal @now - 3600, query.top_jobs(minutes: 481).starts_at
    result = query.top_jobs(hours: 99)

    assert_equal :hourly, result.granularity
    assert_equal @now - (72 * 3600), result.starts_at
  end

  def test_new_hourly_reads_ten_minute_buckets
    Wurk::Metrics::History.record(@klass_a, 10, success: true, at: @now - 120)
    Wurk::Metrics::History.record(@klass_a, 30, success: true, at: @now - 600)
    Wurk::Metrics::History.flush

    job = query.for_job(@klass_a, hours: 1).job_results[@klass_a]

    assert_equal 2, job.totals['p']
    assert_equal({ '2026-05-21T14:30:00Z' => 1, '2026-05-21T14:20:00Z' => 1 }, job.series['p'])
    assert_empty job.hist, 'histograms are only fetched for minute windows'
  end

  def test_new_for_job_carries_totals_series_and_histograms
    Wurk::Metrics::History.record(@klass_a, 25, success: true, at: @now)
    Wurk::Metrics::History.record(@klass_a, 5, success: false, at: @now)
    Wurk::Metrics::History.flush

    job = query.for_job(@klass_a, minutes: 2).job_results[@klass_a]
    hist = job.hist['2026-05-21T14:37:00Z']

    assert_equal [2, 1, 25], job.totals.values_at('p', 'f', 'ms')
    assert_equal({ '2026-05-21T14:37:00Z' => 25.0 }, job.series_avg)
    assert_equal Wurk::Metrics::Histogram::SIZE, hist.size
    assert_equal 1, hist.reverse[1], 'reversed, as upstream: 25ms is the 30ms bucket'
    assert_equal 2, job.hist.size
  end

  def test_new_attaches_deploy_marks_inside_the_window
    Wurk::Deploy.new.mark!(label: "v1#{@suffix}", at: @now - 120)
    Wurk::Deploy.new.mark!(label: "v0#{@suffix}", at: @now - 7200)

    marks = query.top_jobs(minutes: 10).marks

    assert_equal ["v1#{@suffix}"], marks.map(&:label)
    assert_equal '2026-05-21T14:35:00Z', marks.first.bucket
  ensure
    Wurk.redis { |c| c.call('DEL', '20260521-marks') }
  end

  def test_bkt_time_s_truncates_to_the_granularity
    assert_equal '2026-05-21T14:37:00Z', Sidekiq::Metrics::Query.bkt_time_s(@now, :minutely)
    assert_equal '2026-05-21T14:30:00Z', Sidekiq::Metrics::Query.bkt_time_s(@now, :hourly)
  end

  # Data Sidekiq 8.1 wrote before the swap resolves unchanged.
  def test_new_reads_sidekiq_written_buckets
    Wurk.redis do |c|
      c.call('HSET', 'j|260521|14:37', "#{@klass_a}|p", 4, "#{@klass_a}|f", 1, "#{@klass_a}|ms", 90)
      c.call('HSET', 'j|260521|14:3', "#{@klass_b}|p", 9)
    end

    assert_equal 4, query.top_jobs(minutes: 1).job_results[@klass_a].totals['p']
    assert_equal 9, query.top_jobs(hours: 1).job_results[@klass_b].totals['p']
  ensure
    Wurk.redis { |c| c.call('HDEL', 'j|260521|14:3', "#{@klass_b}|p") }
  end

  def test_history_with_window_under_one_step_is_empty
    assert_equal [], Wurk::Metrics::Query.history('5m', 60, now: @now)
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
    names = (0...30).map { |i| format('Qcap%s_%02d', @suffix, i) }
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
