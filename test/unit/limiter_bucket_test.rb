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

  # No block → ArgumentError before any Redis work (line 31 then).
  def test_within_limit_requires_block
    l = Wurk::Limiter.bucket("nb-#{@suffix}", 5, :minute)

    assert_raises(ArgumentError) { l.within_limit }
  end

  # #91: acquire must write to a SINGLE fully-qualified epoch key
  # (lmtr-b:<name>:<epoch>) declared in KEYS[1] — never a bare prefix the script
  # suffixes itself. The old script built the key inside Lua, which Dragonfly
  # rejects (undeclared key) and Redis Cluster would reject (cross-slot if
  # multiple candidates). One declared key is safe on both.
  def test_acquire_writes_a_single_fully_qualified_epoch_key
    name = "dk-#{@suffix}"
    l = Wurk::Limiter.bucket(name, 5, :minute)
    l.within_limit {}

    @pool.with do |c|
      refute_equal 1, c.call('EXISTS', "lmtr-b:#{name}"),
                   'must not write a bare-prefix key (#91)'
      keys = c.call('KEYS', "lmtr-b:#{name}:*")

      assert_equal 1, keys.size, "exactly one declared epoch key, got #{keys.inspect}"
      assert_match(/\Almtr-b:#{Regexp.escape(name)}:\d+\z/, keys.first)
      assert_equal '1', c.call('GET', keys.first)
    end
  end

  # wait_timeout spanning a second-boundary: an exhausted bucket sleeps until
  # the counter rolls to zero, taking the no-raise side (remaining > 0,
  # line 39 else) then succeeding on retry.
  def test_waits_across_boundary_then_succeeds
    l = Wurk::Limiter.bucket("wt-#{@suffix}", 1, :second, wait_timeout: 3)
    l.within_limit {} # exhausts the per-second bucket
    ran = false
    l.within_limit { ran = true } # blocks until the next cardinal second

    assert ran
  end

  # F9: `[remaining, secs_to_next, 0.05].min` always picked the 0.05 floor
  # (remaining and secs_to_next are both bigger almost always), so the old
  # code busy-polled every 50ms instead of sleeping to the boundary. Assert
  # bounds on the sleep *duration* itself — the clock value the retry loop
  # actually waits on — rather than how many times it looped or called Redis,
  # which is an implementation detail that would still pass under the bug.
  def test_wait_sleeps_toward_the_boundary_not_a_fixed_poll_floor
    align_to_top_of_second
    l = Wurk::Limiter.bucket("pb-#{@suffix}", 1, :second, wait_timeout: 3)
    l.within_limit {} # exhausts the current second right after it started

    slept = []
    l.define_singleton_method(:sleep) do |secs|
      slept << secs
      Kernel.sleep(secs)
    end
    ran = false
    l.within_limit { ran = true }

    assert ran
    refute_empty slept
    assert slept.first.between?(0.051, 1.0),
           "first sleep (#{slept.first}) must target the boundary distance, not the 0.05 poll floor"
  end

  private

  # Busy-wait until just past a whole second so the bucket we exhaust next has
  # close to a full second of runway before its boundary — otherwise the test
  # would flake on runs that happen to start near the tail of a second, where
  # even the fixed sleep-to-boundary logic legitimately returns ~0.05s.
  def align_to_top_of_second
    loop do
      now = Time.now.to_f
      break if (now - now.floor) < 0.3

      sleep 0.01
    end
  end
end
