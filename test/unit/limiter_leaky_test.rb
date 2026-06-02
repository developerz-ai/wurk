# frozen_string_literal: true

require_relative '../test_helper'

class LimiterLeakyTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @suffix = "lk#{Process.pid}#{object_id}"
    @pool = Wurk::RedisPool.new(size: 2, url: Wurk::Test.redis_url, timeout: 2, name: 'lkp')
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

  # Non-positive drain / bucket_size silently produces 0 or negative
  # drain_per_sec → division-by-zero in `status` reset_at and degenerate
  # acquire behavior. Fail fast at the boundary instead.
  def test_zero_or_negative_drain_raises
    [0, -1].each do |bad|
      l = Wurk::Limiter.leaky("f0-#{@suffix}-#{bad}", 10, bad)
      assert_raises(ArgumentError) { l.within_limit { nil } }
    end
  end

  def test_zero_or_negative_bucket_size_raises
    l = Wurk::Limiter.leaky("fb-#{@suffix}", 0, 60)
    assert_raises(ArgumentError) { l.within_limit { nil } }
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

  # No block → ArgumentError before any Redis work (line 30 then).
  def test_within_limit_requires_block
    l = Wurk::Limiter.leaky("nb-#{@suffix}", 5, 60)

    assert_raises(ArgumentError) { l.within_limit }
  end

  # Saturated bucket → status reports a future reset_at: the steady drip
  # frees a slot (level >= cap, line 25 then).
  def test_status_reset_at_when_full
    # bucket_size 1 + a single acquire lands level at exactly the cap (the
    # first fill is 0 - 0*drain + 1 = 1.0), so `level >= cap` is exactly true
    # without floating-point drift from inter-acquire leak.
    l = Wurk::Limiter.leaky("st-#{@suffix}", 1, 3600, wait_timeout: 0)
    l.within_limit {}
    s = l.status

    assert_operator s[:reset_at], :>, ::Time.now.to_f
    refute s[:available?]
  end

  # wait_timeout > 0: a full bucket drains while we wait, so the loop takes
  # the no-raise side (remaining > 0, line 38 else) then succeeds on retry.
  def test_waits_and_succeeds_when_capacity_frees_up
    l = Wurk::Limiter.leaky("wt-#{@suffix}", 1, 1, wait_timeout: 5)
    l.within_limit {} # fills the single slot
    ran = false
    l.within_limit { ran = true } # blocks until the drip frees a slot

    assert ran
  end
end
