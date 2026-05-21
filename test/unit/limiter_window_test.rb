# frozen_string_literal: true

require_relative '../test_helper'

class LimiterWindowTest < Wurk::Test::UnitCase
  parallelize_me!

  REDIS_URL = ENV['REDIS_URL'] || 'redis://localhost:6379/0'

  def setup
    super
    @suffix = "wn#{Process.pid}#{object_id}"
    @pool = Wurk::RedisPool.new(size: 2, url: REDIS_URL, timeout: 2, name: 'wnp')
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
    Wurk::Limiter.reset_config!
    Wurk::Limiter.config.redis = @pool
  end

  def teardown
    # Scope cleanup to this test's @suffix so parallel limiter tests don't
    # wipe each other's state mid-run (failure mode: another test's
    # `within_limit` sees an empty counter because we DEL'd its key).
    @pool.with do |c|
      cursor = '0'
      loop do
        cursor, keys = c.call('SCAN', cursor, 'MATCH', "*#{@suffix}*", 'COUNT', 500)
        c.call('DEL', *keys) unless keys.empty?
        break if cursor == '0'
      end
      cursor = '0'
      loop do
        cursor, names = c.call('SSCAN', Wurk::Limiter::LIST_KEY, cursor, 'MATCH', "*#{@suffix}*", 'COUNT', 500)
        c.call('SREM', Wurk::Limiter::LIST_KEY, *names) unless names.empty?
        break if cursor == '0'
      end
    end
    @pool.disconnect!
    Wurk::Limiter.reset_config!
  ensure
    super
  end

  def test_within_limit_yields_block
    l = Wurk::Limiter.window("a-#{@suffix}", 5, :minute)
    ran = false
    l.within_limit { ran = true }

    assert ran
    assert_equal 1, l.size
  end

  def test_full_window_raises_over_limit
    l = Wurk::Limiter.window("b-#{@suffix}", 2, :minute, wait_timeout: 0)
    l.within_limit {}
    l.within_limit {}
    assert_raises(Wurk::Limiter::OverLimit) { l.within_limit {} }
  end

  def test_window_accepts_integer_seconds
    l = Wurk::Limiter.window("c-#{@suffix}", 3, 30, wait_timeout: 0)
    3.times { l.within_limit {} }
    assert_raises(Wurk::Limiter::OverLimit) { l.within_limit {} }
  end

  def test_sliding_window_lets_old_entries_drop_off
    l = Wurk::Limiter.window("d-#{@suffix}", 2, 1, wait_timeout: 0)
    l.within_limit {}
    l.within_limit {}
    sleep 1.2
    l.within_limit {}

    assert_operator l.size, :<=, 2
  end

  def test_used_parameter_adds_multiple_entries
    l = Wurk::Limiter.window("e-#{@suffix}", 5, :minute)
    l.within_limit(used: 3) {}

    assert_equal 3, l.size
  end

  def test_used_overage_raises_when_remaining_too_small
    l = Wurk::Limiter.window("f-#{@suffix}", 3, :minute, wait_timeout: 0)
    l.within_limit(used: 2) {}
    assert_raises(Wurk::Limiter::OverLimit) { l.within_limit(used: 2) {} }
  end

  def test_reset_clears_window
    l = Wurk::Limiter.window("g-#{@suffix}", 5, :minute)
    l.within_limit {}
    l.within_limit {}
    l.reset

    assert_equal 0, l.size
  end

  def test_block_exception_still_charges_window
    l = Wurk::Limiter.window("h-#{@suffix}", 5, :minute)
    assert_raises(RuntimeError) { l.within_limit { raise 'boom' } }
    assert_equal 1, l.size
  end

  def test_options_exposes_input_params
    l = Wurk::Limiter.window("i-#{@suffix}", 4, :second)

    assert_equal 4, l.options[:count]
    assert_equal :second, l.options[:interval]
  end
end
