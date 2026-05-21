# frozen_string_literal: true

require_relative '../test_helper'

class LimiterConcurrentTest < Wurk::Test::UnitCase
  parallelize_me!

  REDIS_URL = ENV['REDIS_URL'] || 'redis://localhost:6379/0'

  def setup
    super
    @suffix = "cc#{Process.pid}#{object_id}"
    @pool = Wurk::RedisPool.new(size: 4, url: REDIS_URL, timeout: 2, name: 'ccp')
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

  def test_acquires_one_slot_and_yields_block
    l = Wurk::Limiter.concurrent("a-#{@suffix}", 1)
    ran = false
    l.within_limit { ran = true }

    assert ran
    assert_equal 0, l.size
  end

  def test_raises_over_limit_when_full_and_wait_zero
    l = Wurk::Limiter.concurrent("b-#{@suffix}", 1, wait_timeout: 0)
    assert_raises(Wurk::Limiter::OverLimit) do
      l.within_limit do
        # nested call from another "thread" emulated via second limiter instance
        l2 = Wurk::Limiter.concurrent("b-#{@suffix}", 1, wait_timeout: 0)

        l2.within_limit { flunk 'should not enter' }
      end
    end
  end

  def test_policy_ignore_skips_block_silently_when_full
    l1 = Wurk::Limiter.concurrent("c-#{@suffix}", 1, wait_timeout: 0, policy: :ignore)
    ran = false
    l1.within_limit do
      l2 = Wurk::Limiter.concurrent("c-#{@suffix}", 1, wait_timeout: 0, policy: :ignore)
      l2.within_limit { ran = true }
    end

    refute ran, 'inner block should be skipped silently'
  end

  def test_two_holders_run_when_limit_two
    l = Wurk::Limiter.concurrent("d-#{@suffix}", 2)
    count = 0
    l.within_limit do
      count += 1
      l.within_limit { count += 1 }
    end

    assert_equal 2, count
  end

  def test_size_reflects_active_holders
    l = Wurk::Limiter.concurrent("e-#{@suffix}", 2)

    l.within_limit do
      assert_equal 1, l.size
    end
    assert_equal 0, l.size
  end

  def test_release_removes_slot_after_block
    l = Wurk::Limiter.concurrent("f-#{@suffix}", 1)
    l.within_limit {}

    assert_equal 0, l.size
  end

  def test_block_exception_still_releases_slot
    l = Wurk::Limiter.concurrent("g-#{@suffix}", 1)
    assert_raises(RuntimeError) do
      l.within_limit { raise 'boom' }
    end
    assert_equal 0, l.size
  end

  def test_lock_timeout_reclaims_expired_slots
    l = Wurk::Limiter.concurrent("h-#{@suffix}", 1, lock_timeout: 1, wait_timeout: 2)
    # Manually inject an expired slot at score 1 (well in the past).
    @pool.with { |c| c.call('ZADD', "lmtr-cs:h-#{@suffix}", 1, 'orphan') }
    ran = false
    l.within_limit { ran = true }

    assert ran
    assert_operator l.status['reclaimed'], :>=, 1
  end

  def test_status_returns_metrics_hash
    l = Wurk::Limiter.concurrent("i-#{@suffix}", 1)
    l.within_limit {}
    s = l.status

    assert_kind_of Hash, s
    assert s.key?('immediate')
    assert_operator s['immediate'].to_i + s['waited'].to_i, :>=, 1
  end

  def test_reset_clears_state
    l = Wurk::Limiter.concurrent("j-#{@suffix}", 1)
    @pool.with { |c| c.call('ZADD', "lmtr-cs:j-#{@suffix}", ::Time.now.to_i + 30, 'x') }
    l.reset

    assert_equal 0, l.size
  end

  def test_options_exposes_input_params
    l = Wurk::Limiter.concurrent("k-#{@suffix}", 7, lock_timeout: 11, wait_timeout: 3)

    assert_equal 7, l.options[:limit]
    assert_equal 11, l.options[:lock_timeout]
    assert_equal 3, l.options[:wait_timeout]
  end
end
