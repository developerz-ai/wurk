# frozen_string_literal: true

require_relative '../test_helper'

# Pins the Ent §5 Historical Metrics snapshotter (Wurk::History) and the
# `config.retain_history` DSL: leader-gated periodic emit, the default §5.2
# gauge set, a custom collector block, and the Sidekiq::History alias.
#
# Mutates global Wurk.configuration.dogstatsd + the history config + the
# Statsd client singleton, so it holds the suite-wide STATSD_MUTEX around #run
# like MetricsStatsdTest.
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

  def setup
    super
    @config = Wurk.configuration
    @prev_builder = @config.dogstatsd
    @prev_interval = @config[:history_interval]
    @prev_collector = @config[:history_collector]
    Wurk::Metrics::Statsd.reset!
  end

  def teardown
    @config.dogstatsd = @prev_builder
    @config[:history_interval] = @prev_interval
    @config[:history_collector] = @prev_collector
    Wurk::Metrics::Statsd.reset!
  ensure
    super
  end

  # --- alias + config DSL ----------------------------------------------

  def test_aliased_as_sidekiq_history
    assert_same Wurk::History, Sidekiq::History
  end

  def test_retain_history_enables_and_stores_interval
    @config.retain_history(45)

    assert_predicate @config, :history_enabled?
    assert_in_delta 45.0, @config.history_interval, 0.001
  end

  def test_retain_history_rejects_non_positive_interval
    assert_raises(ArgumentError) { @config.retain_history(0) }
    assert_raises(ArgumentError) { @config.retain_history(-5) }
  end

  def test_history_disabled_by_default_on_a_fresh_config
    refute_predicate Wurk::Configuration.new, :history_enabled?
  end

  # --- default §5.2 snapshot -------------------------------------------

  def test_default_snapshot_emits_the_section_5_2_gauge_set
    fake = FakeClient.new
    @config.dogstatsd = fake
    @config.retain_history(30)
    seed_queue('hq', 3) # teardown FLUSHDBs, so no manual cleanup needed

    Wurk::History.new(@config).snapshot
    emitted = fake.gauges.to_h

    assert_equal SECTION_5_2.sort, emitted.keys.sort
    assert_equal 3, emitted['sidekiq.enqueued']
  end

  # --- custom collector -------------------------------------------------

  def test_custom_collector_receives_the_dogstatsd_client
    fake = FakeClient.new
    @config.dogstatsd = fake
    seen = nil
    @config.retain_history(30) { |s| seen = s }

    Wurk::History.new(@config).snapshot

    assert_same fake, seen
  end

  def test_custom_collector_replaces_the_default_set
    fake = FakeClient.new
    @config.dogstatsd = fake
    @config.retain_history(30) { |s| s.gauge('sidekiq.custom', 7) }

    Wurk::History.new(@config).snapshot

    assert_equal [['sidekiq.custom', 7]], fake.gauges
  end

  def test_snapshot_is_a_noop_without_a_dogstatsd_client
    @config.dogstatsd = nil
    @config.retain_history(30)

    assert_nil Wurk::History.new(@config).snapshot
  end

  # --- leader gate ------------------------------------------------------

  def test_tick_emits_when_leader
    fake = FakeClient.new
    @config.dogstatsd = fake
    @config.retain_history(30)
    history = Wurk::History.new(@config)
    history.define_singleton_method(:leader?) { true }

    history.tick

    refute_empty fake.gauges
  end

  def test_tick_is_leader_gated
    fake = FakeClient.new
    @config.dogstatsd = fake
    @config.retain_history(30)
    history = Wurk::History.new(@config)
    history.define_singleton_method(:leader?) { false }

    history.tick

    assert_empty fake.gauges
  end

  # --- background thread loop ------------------------------------------

  def test_start_loop_snapshots_until_terminated
    @config.retain_history(0.01)
    history = Wurk::History.new(@config)
    history.define_singleton_method(:leader?) { true }
    history.define_singleton_method(:snapshot) { @snaps = (@snaps || 0) + 1 }

    history.start
    poll_until(2.0) { history.instance_variable_get(:@snaps).to_i.positive? }
    history.terminate

    assert_operator history.instance_variable_get(:@snaps).to_i, :>, 0
  end

  private

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
