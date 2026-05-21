# frozen_string_literal: true

require_relative '../test_helper'

class LimiterPointsTest < Wurk::Test::UnitCase
  parallelize_me!

  REDIS_URL = ENV['REDIS_URL'] || 'redis://localhost:6379/0'

  def setup
    super
    @suffix = "pt#{Process.pid}#{object_id}"
    @pool = Wurk::RedisPool.new(size: 2, url: REDIS_URL, timeout: 2, name: 'ptp')
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
    Wurk::Limiter.reset_config!
    Wurk::Limiter.config.redis = @pool
  end

  def teardown
    @pool.with do |c|
      cursor = '0'
      loop do
        cursor, keys = c.call('SCAN', cursor, 'MATCH', 'lmtr*', 'COUNT', 500)
        c.call('DEL', *keys) unless keys.empty?
        break if cursor == '0'
      end
    end
    @pool.disconnect!
    Wurk::Limiter.reset_config!
  ensure
    super
  end

  def test_within_limit_yields_handle
    l = Wurk::Limiter.points("a-#{@suffix}", 100, 10)
    got_handle = nil
    l.within_limit(estimate: 10) { |h| got_handle = h }

    refute_nil got_handle
    assert_respond_to got_handle, :points_used
  end

  def test_charges_estimate_from_balance
    l = Wurk::Limiter.points("b-#{@suffix}", 100, 0)
    l.within_limit(estimate: 30) { |_h| }

    assert_in_delta 70, l.size, 0.1
  end

  def test_immediately_raises_when_balance_below_estimate
    l = Wurk::Limiter.points("c-#{@suffix}", 50, 0)
    assert_raises(Wurk::Limiter::OverLimit) do
      l.within_limit(estimate: 100) { |_h| flunk 'should not enter' }
    end
  end

  def test_handle_points_used_refunds_overestimate
    # Charged 50, only used 20 → refund 30 → balance = 100 - 20 = 80.
    l = Wurk::Limiter.points("d-#{@suffix}", 100, 0)
    l.within_limit(estimate: 50) { |h| h.points_used(20) }

    assert_in_delta 80, l.size, 0.1
  end

  def test_handle_points_used_records_under_estimate
    l = Wurk::Limiter.points("e-#{@suffix}", 100, 0)
    l.within_limit(estimate: 10) { |h| h.points_used(30) }

    assert_in_delta 70, l.size, 0.1
  end

  def test_refill_replenishes_over_time
    l = Wurk::Limiter.points("f-#{@suffix}", 100, 50)
    l.within_limit(estimate: 100) { |_h| }

    assert_in_delta 0, l.size, 1
    sleep 0.5
    l.within_limit(estimate: 20) { |_h| }
  end

  def test_refill_caps_at_initial
    l = Wurk::Limiter.points("g-#{@suffix}", 100, 1_000_000)
    l.within_limit(estimate: 10) { |_h| }
    sleep 0.05

    assert_in_delta 100, l.size, 1
  end

  def test_negative_estimate_rejected
    l = Wurk::Limiter.points("h-#{@suffix}", 100, 0)
    assert_raises(ArgumentError) { l.within_limit(estimate: 0) { |_h| } }
  end

  def test_reset_restores_full_balance_on_next_acquire
    l = Wurk::Limiter.points("i-#{@suffix}", 100, 0)
    l.within_limit(estimate: 50) { |_h| }
    l.reset
    # After reset, balance defaults to `initial` per the Lua acquire.
    l.within_limit(estimate: 90) { |_h| }
  end

  def test_options_exposes_input_params
    l = Wurk::Limiter.points("j-#{@suffix}", 200, 3)

    assert_equal 200, l.options[:initial]
    assert_equal 3, l.options[:refill]
  end
end
