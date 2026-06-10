# frozen_string_literal: true

require_relative '../test_helper'

# Pins the Ent §5 Historical Metrics snapshotter (Wurk::History) and the
# `config.retain_history` DSL: leader-gated periodic emit, the default §5.2
# gauge set, a custom collector block, and the Sidekiq::History alias.
#
# `retain_history` is always exercised on a FRESH Wurk::Configuration so the
# process-global config's history keys never leak across tests; only the
# global `dogstatsd` (read by Wurk::Metrics::Statsd.client) is mutated, and
# it's saved/restored. Holds the suite-wide STATSD_MUTEX around #run like
# MetricsStatsdTest, since the Statsd client singleton is process-global.
class HistoryTest < Wurk::Test::UnitCase
  parallelize_me!

  def run(*args, &)
    Wurk::Test::STATSD_MUTEX.synchronize { super }
  end

  # Records every gauge so a test can assert the exact §5.2 metric set.
  class FakeClient
    attr_reader :gauges

    def initialize
      @gauges = []
    end

    def gauge(metric, value, **_opts)
      @gauges << [metric, value]
    end
  end

  SECTION_5_2 = %w[
    sidekiq.processed sidekiq.failures sidekiq.enqueued sidekiq.retries
    sidekiq.dead sidekiq.scheduled sidekiq.busy
  ].freeze

  # The same metrics as stream fields (no `sidekiq.` prefix), as symbols.
  STREAM_FIELDS = Wurk::History::SNAPSHOT_FIELDS.keys.map(&:to_sym).freeze

  def setup
    super
    @prev_builder = Wurk.configuration.dogstatsd
    Wurk::Metrics::Statsd.reset!
  end

  def teardown
    Wurk.configuration.dogstatsd = @prev_builder
    Wurk::Metrics::Statsd.reset!
  ensure
    super
  end

  # --- alias + config DSL ----------------------------------------------

  def test_aliased_as_sidekiq_history
    assert_same Wurk::History, Sidekiq::History
  end

  def test_retain_history_enables_and_stores_interval
    config = Wurk::Configuration.new
    config.retain_history(45)

    assert_predicate config, :history_enabled?
    assert_in_delta 45.0, config.history_interval, 0.001
  end

  def test_retain_history_rejects_non_positive_interval
    config = Wurk::Configuration.new

    assert_raises(ArgumentError) { config.retain_history(0) }
    assert_raises(ArgumentError) { config.retain_history(-5) }
  end

  def test_history_disabled_by_default_on_a_fresh_config
    refute_predicate Wurk::Configuration.new, :history_enabled?
  end

  # --- default §5.2 snapshot -------------------------------------------

  def test_default_snapshot_emits_the_section_5_2_gauge_set
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    seed_queue('hq', 3) # teardown FLUSHDBs, so no manual cleanup needed

    history.snapshot
    emitted = fake.gauges.to_h

    assert_equal SECTION_5_2.sort, emitted.keys.sort
    assert_equal 3, emitted['sidekiq.enqueued']
  end

  # --- custom collector -------------------------------------------------

  def test_custom_collector_receives_the_dogstatsd_client
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    seen = nil

    history { |s| seen = s }.snapshot

    assert_same fake, seen
  end

  def test_custom_collector_replaces_the_default_set
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    history { |s| s.gauge('sidekiq.custom', 7) }.snapshot

    assert_equal [['sidekiq.custom', 7]], fake.gauges
  end

  def test_snapshot_skips_statsd_but_still_records_the_stream_without_a_client
    Wurk.configuration.dogstatsd = nil

    history.snapshot

    assert_equal(1, Wurk.redis { |c| c.call('XLEN', Wurk::Keys::HISTORY_METRICS) })
  end

  # --- leader gate ------------------------------------------------------

  def test_tick_emits_when_leader
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    snapshotter = history
    snapshotter.define_singleton_method(:leader?) { true }

    snapshotter.tick

    refute_empty fake.gauges
  end

  def test_tick_is_leader_gated
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    snapshotter = history
    snapshotter.define_singleton_method(:leader?) { false }

    snapshotter.tick

    assert_empty fake.gauges
  end

  # --- background thread loop ------------------------------------------

  def test_start_loop_snapshots_until_terminated
    snapshotter = history(interval: 0.01)
    snapshotter.define_singleton_method(:leader?) { true }
    snapshotter.define_singleton_method(:snapshot) { @snaps = (@snaps || 0) + 1 }

    snapshotter.start
    poll_until(2.0) { snapshotter.instance_variable_get(:@snaps).to_i.positive? }
    snapshotter.terminate

    assert_operator snapshotter.instance_variable_get(:@snaps).to_i, :>, 0
  end

  # --- history:metrics stream (§5.3) -----------------------------------

  def test_snapshot_appends_the_section_5_2_fields_to_the_stream
    seed_queue('hq', 4)

    history.snapshot
    point = Wurk::History.recent.last

    assert_equal STREAM_FIELDS.sort, (point.keys - [:at]).sort
    assert_equal 4, point[:enqueued]
  end

  def test_recent_returns_points_oldest_to_newest
    3.times do |i|
      seed_queue("hq#{i}", i + 1)
      history.snapshot
    end
    points = Wurk::History.recent

    assert_equal 3, points.size
    assert_equal(points.map { |p| p[:at] }.sort, points.map { |p| p[:at] })
  end

  def test_recent_clamps_to_the_requested_count
    5.times { history.snapshot }

    assert_equal 2, Wurk::History.recent(limit: 2).size
  end

  # AC: a migrated Ent install's entries render without rewrite — fields are
  # read generically (numeric coerced, non-numeric kept).
  def test_recent_tolerates_foreign_ent_stream_fields
    Wurk.redis { |c| c.call('XADD', Wurk::Keys::HISTORY_METRICS, '*', 'processed', '999', 'odd_field', '12', 'label', 'x') }
    point = Wurk::History.recent.last

    assert_equal 999, point[:processed]
    assert_equal 12, point[:odd_field]
    assert_equal 'x', point[:label]
  end

  def test_stream_is_capped_by_maxlen
    snapshotter = history(cap: 10)
    200.times { snapshotter.snapshot }
    xlen = Wurk.redis { |c| c.call('XLEN', Wurk::Keys::HISTORY_METRICS) }

    assert_operator xlen, :<, 200, 'MAXLEN ~ should trim the stream'
  end

  private

  # A History built on a throwaway config so retain_history never mutates the
  # process-global Wurk.configuration. The config's Redis is pinned to this
  # worker's test DB (a fresh Configuration would otherwise default to DB 0,
  # which tests must never touch) so the stream write lands where recent() reads.
  def history(interval: 30, cap: nil, &collector)
    config = Wurk::Configuration.new
    config.redis = { url: Wurk::Test.redis_url }
    config[:history_stream_cap] = cap if cap
    config.retain_history(interval, &collector)
    Wurk::History.new(config)
  end

  def seed_queue(name, depth)
    Wurk.redis do |c|
      c.call('SADD', 'queues', name)
      depth.times { c.call('RPUSH', "queue:#{name}", '{}') }
    end
  end

  def poll_until(timeout)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    sleep(0.005) until yield || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
  end
end
