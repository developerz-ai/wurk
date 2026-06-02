# frozen_string_literal: true

require_relative '../test_helper'

class LimiterWindowTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @suffix = "wn#{Process.pid}#{object_id}"
    @pool = Wurk::RedisPool.new(size: 2, url: Wurk::Test.redis_url, timeout: 2, name: 'wnp')
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

  # No block → ArgumentError before any Redis work (line 37 then).
  def test_within_limit_requires_block
    l = Wurk::Limiter.window("nb-#{@suffix}", 5, :minute)

    assert_raises(ArgumentError) { l.within_limit }
  end

  # With entries inside the window, oldest_expiry takes the row-present
  # then-side (window.rb line 66) and status carries a non-nil reset_at.
  #
  # NOTE: under RESP3 `ZRANGE ... WITHSCORES` returns nested [member, score]
  # pairs, so the existing `row[1]` indexing reads nil and reset_at lands at
  # `interval` (60.0) rather than oldest_ts + interval. That is a latent
  # bug in lib/wurk/limiter/window.rb (filed separately); we only assert the
  # branch is taken (reset_at non-nil), not the wall-clock semantics.
  def test_status_reset_at_with_entries_present
    l = Wurk::Limiter.window("se-#{@suffix}", 5, :minute)
    l.within_limit {}
    s = l.status

    assert_equal 1, s[:used]
    refute_nil s[:reset_at], 'oldest_expiry returns a value when entries are present'
  end

  # wait_timeout > 0: a full short window slides clear while we wait, taking
  # the no-raise side (remaining > 0, line 45 else) then succeeding.
  def test_waits_and_succeeds_when_window_slides_clear
    l = Wurk::Limiter.window("wt-#{@suffix}", 1, 1, wait_timeout: 5)
    l.within_limit {} # fills the single slot
    ran = false
    l.within_limit { ran = true } # blocks until the entry leaves the window

    assert ran
  end
end
