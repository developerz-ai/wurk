# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

class MetricsFlusherTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @at = ::Time.utc(2026, 5, 21, 14, 37, 12)
    @klass = "FlushJob-#{SecureRandom.hex(8)}"
    @acc = Wurk::Metrics::Accumulator.new
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @reported = []
    @config.error_handlers << ->(ex, ctx, _cfg) { @reported << [ex.message, ctx[:context]] }
  end

  def teardown
    Wurk.redis do |c|
      c.call('UNLINK', Wurk::Metrics::History.hour_key(@klass, @at))
      c.call('HDEL', minute_key, "#{@klass}|p", "#{@klass}|f", "#{@klass}|ms")
    end
  ensure
    super
  end

  def test_uses_the_history_flush_interval
    assert_equal 5, Wurk::Metrics::History::FLUSH_INTERVAL
  end

  def test_defaults_to_the_process_wide_accumulator
    flusher = Wurk::Metrics::Flusher.new(@config)

    assert_same Wurk::Metrics::History::ACCUMULATOR, flusher.instance_variable_get(:@accumulator)
  end

  def test_start_is_idempotent
    flusher = build_flusher
    thread = flusher.start

    assert_same thread, flusher.start
  ensure
    flusher.terminate
  end

  def test_tick_drains_the_accumulator_into_redis
    accumulate(2, ms: 40)

    build_flusher.tick

    assert_equal '2', processed
    assert_predicate @acc, :empty?
  end

  # Every other periodic component the Launcher runs is leader-gated. This one
  # must not be: the counters it writes exist only in this process's memory, so
  # a gate would strand every follower's metrics until it died. Raising from
  # `leader?` turns "consulted the gate" into a failed flush.
  def test_tick_never_consults_the_leader_lock
    flusher = build_flusher
    flusher.define_singleton_method(:leader?) { raise 'leader gate consulted' }
    accumulate(1)

    flusher.tick

    assert_equal '1', processed
  end

  # tick runs on a safe_thread, whose watchdog re-raises after reporting — a
  # flusher that died on a blip would silently stop every counter in the process
  # for something Redis recovers from.
  def test_tick_reports_a_failed_flush_without_raising_or_dropping_the_window
    @acc.add(BrokenPool.new, @klass, @at.to_i / 60, 1, true)

    build_flusher.tick

    assert_equal [['redis down', 'metrics-flush']], @reported
    refute_predicate @acc, :empty?
  end

  # The signed-off cost is that a *hard* kill drops the unflushed window. A
  # graceful stop must not: terminate stops the only thread that would have
  # written it, so it writes it itself on the way out.
  def test_terminate_flushes_the_window_accumulated_since_the_last_tick
    flusher = build_flusher
    flusher.start
    accumulate(3, ms: 7)

    flusher.terminate

    assert_equal '3', processed
  end

  def test_terminate_flushes_even_when_the_loop_was_never_started
    accumulate(1)

    build_flusher.terminate

    assert_equal '1', processed
  end

  class BrokenPool
    def with(&)
      raise 'redis down'
    end
  end

  private

  def build_flusher
    Wurk::Metrics::Flusher.new(@config, accumulator: @acc)
  end

  def accumulate(count, ms: 1)
    count.times { @acc.add(nil, @klass, @at.to_i / 60, ms, true) }
  end

  def minute_key
    Wurk::Metrics::History.minute_key(@at)
  end

  def processed
    Wurk.redis { |c| c.call('HGET', minute_key, "#{@klass}|p") }
  end
end
