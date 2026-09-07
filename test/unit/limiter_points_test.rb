# frozen_string_literal: true

require_relative '../test_helper'

class LimiterPointsTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @suffix = "pt#{Process.pid}#{object_id}"
    @pool = Wurk::RedisPool.new(size: 2, url: Wurk::Test.redis_url, timeout: 2, name: 'ptp')
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
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    l.within_limit(estimate: 100) { |_h| }

    # The bucket refills at 50 points/s from the moment it was created, so by the
    # time this line runs it already holds 50 x elapsed points; on a loaded CI
    # runner that was 1.16 with a fixed tolerance of 1 (2026-09-03). Bound the
    # size by the refill the clock actually allowed, never by a guessed constant.
    # Read the balance FIRST, then take the clock: the read is a Redis round trip
    # plus the refill maths, and a bound captured before it is a bound the read
    # can legitimately exceed on a paused runner.
    size = l.size
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator size, :<=, (50 * elapsed) + 1
    assert_operator size, :>=, 0
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

  # No block → ArgumentError before any Redis work (line 54 then).
  def test_within_limit_requires_block
    l = Wurk::Limiter.points("nb-#{@suffix}", 100, 10)

    assert_raises(ArgumentError) { l.within_limit(estimate: 10) }
  end

  # After consuming below the cap with a positive refill, status.reset_at is
  # when the bucket refills to full (available < cap && refill positive,
  # line 49 then).
  def test_status_reset_at_when_consumed_with_positive_refill
    l = Wurk::Limiter.points("sr-#{@suffix}", 100, 5)
    l.within_limit(estimate: 40) { |_h| }
    s = l.status

    assert_operator s[:used], :>, 0
    assert_operator s[:reset_at], :>, ::Time.now.to_f
  end
end
