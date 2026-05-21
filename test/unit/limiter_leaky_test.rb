# frozen_string_literal: true

require_relative '../test_helper'

class LimiterLeakyTest < Wurk::Test::UnitCase
  parallelize_me!

  REDIS_URL = ENV['REDIS_URL'] || 'redis://localhost:6379/0'

  def setup
    super
    @suffix = "lk#{Process.pid}#{object_id}"
    @pool = Wurk::RedisPool.new(size: 2, url: REDIS_URL, timeout: 2, name: 'lkp')
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

  def test_within_limit_yields
    l = Wurk::Limiter.leaky("a-#{@suffix}", 5, :second)
    ran = false
    l.within_limit { ran = true }

    assert ran
    assert_operator l.size, :>, 0
  end

  def test_overflows_when_bucket_full
    l = Wurk::Limiter.leaky("b-#{@suffix}", 3, 60, wait_timeout: 0)
    3.times { l.within_limit {} }
    assert_raises(Wurk::Limiter::OverLimit) { l.within_limit {} }
  end

  def test_leak_replenishes_capacity_over_time
    l = Wurk::Limiter.leaky("c-#{@suffix}", 2, 1, wait_timeout: 0)
    2.times { l.within_limit {} }
    sleep 1.5
    l.within_limit {}
  end

  def test_drain_as_integer_seconds
    l = Wurk::Limiter.leaky("d-#{@suffix}", 10, 60)
    l.within_limit {}

    assert_operator l.size, :>, 0
  end

  def test_drain_as_symbol_unit
    l = Wurk::Limiter.leaky("e-#{@suffix}", 10, :minute)
    l.within_limit {}

    assert_operator l.size, :>, 0
  end

  def test_invalid_drain_type_raises
    l = Wurk::Limiter.leaky("f-#{@suffix}", 10, 'bogus')
    assert_raises(ArgumentError) { l.within_limit {} }
  end

  def test_reset_clears_level
    l = Wurk::Limiter.leaky("g-#{@suffix}", 3, 60)
    l.within_limit {}
    l.reset

    assert_equal 0, l.size
  end

  def test_block_exception_still_charges
    l = Wurk::Limiter.leaky("h-#{@suffix}", 5, 60)
    assert_raises(RuntimeError) { l.within_limit { raise 'boom' } }
    assert_operator l.size, :>, 0
  end

  def test_options_exposes_input_params
    l = Wurk::Limiter.leaky("i-#{@suffix}", 7, :second)

    assert_equal 7, l.options[:bucket_size]
    assert_equal :second, l.options[:drain]
  end
end
