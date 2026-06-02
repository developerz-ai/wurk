# frozen_string_literal: true

require_relative '../test_helper'

class LimiterBucketTest < Wurk::Test::UnitCase
  parallelize_me!


  def setup
    super
    @suffix = "bk#{Process.pid}#{object_id}"
    @pool = Wurk::RedisPool.new(size: 2, url: Wurk::Test.redis_url, timeout: 2, name: 'bkp')
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

  def test_first_call_increments_bucket_and_yields
    l = Wurk::Limiter.bucket("a-#{@suffix}", 5, :minute)
    ran = false
    l.within_limit { ran = true }

    assert ran
    assert_equal 1, l.size
  end

  def test_exhausted_bucket_raises_over_limit_with_zero_wait
    l = Wurk::Limiter.bucket("b-#{@suffix}", 2, :minute, wait_timeout: 0)
    l.within_limit {}
    l.within_limit {}
    assert_raises(Wurk::Limiter::OverLimit) { l.within_limit {} }
  end

  def test_within_limit_accepts_used_parameter
    l = Wurk::Limiter.bucket("c-#{@suffix}", 5, :minute)
    l.within_limit(used: 3) {}

    assert_equal 3, l.size
  end

  def test_rejects_overage_when_used_exceeds_remaining
    l = Wurk::Limiter.bucket("d-#{@suffix}", 2, :minute, wait_timeout: 0)
    l.within_limit(used: 2) {}
    assert_raises(Wurk::Limiter::OverLimit) { l.within_limit(used: 1) {} }
  end

  def test_interval_symbols_map_to_seconds
    %i[second minute hour day].each do |interval|
      l = Wurk::Limiter.bucket("e-#{interval}-#{@suffix}", 1, interval)
      l.within_limit {}

      assert_equal 1, l.size
    end
  end

  def test_integer_interval_is_rejected_for_bucket
    assert_raises(ArgumentError) { Wurk::Limiter.bucket("f-#{@suffix}", 1, 60) }
  end

  def test_unknown_interval_symbol_is_rejected
    assert_raises(ArgumentError) { Wurk::Limiter.bucket("g-#{@suffix}", 1, :fortnight) }
  end

  def test_block_exception_still_counts_against_bucket
    # Bucket increments at acquire time, before yield — exceptions don't refund.
    l = Wurk::Limiter.bucket("h-#{@suffix}", 5, :minute)
    assert_raises(RuntimeError) { l.within_limit { raise 'boom' } }
    assert_equal 1, l.size
  end

  def test_options_exposes_input_params
    l = Wurk::Limiter.bucket("i-#{@suffix}", 9, :hour, reschedule: 3)

    assert_equal 9, l.options[:count]
    assert_equal :hour, l.options[:interval]
    assert_equal 3, l.options[:reschedule]
  end
end
