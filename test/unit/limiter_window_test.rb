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
  # then-side and status carries reset_at = oldest_ts + interval. The oldest
  # entry was just added, so reset_at lands ~`interval` seconds in the future.
  # Asserting it exceeds `now` catches the flat-vs-nested RESP3 ZRANGE bug,
  # which would collapse oldest_ts to 0.0 and leave reset_at at a bare 60.0.
  def test_status_reset_at_with_entries_present
    l = Wurk::Limiter.window("se-#{@suffix}", 5, :minute)
    before = Time.now.to_f
    l.within_limit {}
    s = l.status

    assert_equal 1, s[:used]
    assert_operator s[:reset_at], :>, before, 'reset_at = oldest_ts + interval, not a bare 60.0'
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

  # ----- read-only introspection ---------------------------------------

  # Reads are scoped by the Redis clock: an entry that has already slid out of
  # the window is invisible to `size`, and `reset_at` tracks the oldest entry
  # still *inside* it (a bare `ZRANGE 0 0` would report the stale one and put
  # reset_at in the past).
  def test_read_ignores_stale_entries
    l = window_with_stale_entry('ro')
    s = l.status

    assert_equal 1, s[:used]
    assert_operator s[:reset_at], :>, ::Time.now.to_f, 'reset_at must come from the live entry, not the stale one'
  end

  # Trimming belongs to the acquire script alone — a status read leaves the
  # ZSET byte-for-byte as it found it.
  def test_read_never_trims_the_window
    l = window_with_stale_entry('rt')
    l.status

    assert_equal 1, l.size
    assert_equal 2, zcard('rt'), 'a read must not evict anything'
  end

  # F8: the read path takes its cutoff from Redis TIME, so a dashboard host
  # whose clock runs an hour ahead still sees a full window. The old
  # client-clock trim wiped every entry here.
  def test_read_is_immune_to_client_clock_skew
    l = Wurk::Limiter.window("sk-#{@suffix}", 2, 60, wait_timeout: 0)
    2.times { l.within_limit {} }
    s = with_time_now(::Time.now.to_f + 3600) { l.status }

    assert_equal 2, s[:used]
    refute s[:available?]
    assert_equal 2, zcard('sk'), 'a skewed client must not evict live entries'
  end

  # ...and the window it did not evict still holds the limit closed.
  def test_acquire_still_enforces_limit_after_a_skewed_read
    l = Wurk::Limiter.window("se2-#{@suffix}", 2, 60, wait_timeout: 0)
    2.times { l.within_limit {} }
    with_time_now(::Time.now.to_f + 3600) { l.size }

    assert_raises(Wurk::Limiter::OverLimit) { l.within_limit {} }
  end

  private

  # One live entry (just charged) plus one that left the window two intervals
  # ago, written straight to Redis so the acquire script never sees it.
  def window_with_stale_entry(prefix)
    l = Wurk::Limiter.window("#{prefix}-#{@suffix}", 5, 60)
    l.within_limit {}
    @pool.with { |c| c.call('ZADD', window_key(prefix), c.call('TIME').first.to_i - 120, 'stale') }
    l
  end

  def window_key(prefix)
    "lmtr-w:#{prefix}-#{@suffix}"
  end

  def zcard(prefix)
    @pool.with { |c| c.call('ZCARD', window_key(prefix)).to_i }
  end

  # Minitest 6 dropped `Time.stub`; hand-rolled override pins Time.now for the
  # block. Process-wide, which is safe because minitest-parallel_fork gives each
  # test class its own worker process (UnitCase.parallelize_me! is a marker for
  # that runner, not Minitest's in-process thread pool).
  def with_time_now(epoch_f)
    frozen = ::Time.at(epoch_f)
    sc = ::Time.singleton_class
    original = ::Time.method(:now)
    sc.define_method(:now) { frozen }
    begin
      yield
    ensure
      sc.define_method(:now) { |*a, &b| original.call(*a, &b) }
    end
  end
end
