# frozen_string_literal: true

require_relative '../test_helper'

# Contention stress for the Lua-backed limiters (#16 "Done when"). Real
# Redis, real threads: hammer a concurrent limiter from many threads and
# assert the atomic slot count is never breached — i.e. the acquire Lua
# script is genuinely atomic and EVALSHA-cached under load.
class LimiterStressTest < Wurk::Test::UnitCase
  parallelize_me!

  THREADS = 50
  PER_THREAD = 20 # THREADS * PER_THREAD = 1000 acquires

  def setup
    super
    @suffix = "stress#{Process.pid}:#{object_id}"
    # A pool wide enough that 50 threads never starve on a connection (which
    # would surface as a pool timeout, not a limiter decision).
    @pool = Wurk::RedisPool.new(size: THREADS + 8, url: Wurk::Test.redis_url, timeout: 5, name: 'lstress')
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
    Wurk::Limiter.reset_config!
    Wurk::Limiter.config.redis = @pool
  end

  def teardown
    Wurk::Limiter.concurrent("c-#{@suffix}", 1).delete
    Wurk::Limiter.reset_config!
    @pool.disconnect!
  ensure
    super
  end

  def test_1000_concurrent_acquires_never_exceed_the_limit # rubocop:disable Minitest/MultipleAssertions,Metrics/AbcSize
    limit = 5
    limiter = Wurk::Limiter.concurrent("c-#{@suffix}", limit, wait_timeout: 15, lock_timeout: 30)

    mutex = ::Mutex.new
    in_flight = 0
    max_seen = 0
    acquired = 0
    over_limit = 0

    threads = Array.new(THREADS) do
      ::Thread.new do
        PER_THREAD.times do
          limiter.within_limit do
            mutex.synchronize do
              in_flight += 1
              max_seen = in_flight if in_flight > max_seen
              acquired += 1
            end
            sleep 0.002 # widen the window so any non-atomic slip would overlap
            mutex.synchronize { in_flight -= 1 }
          end
        rescue Wurk::Limiter::OverLimit
          mutex.synchronize { over_limit += 1 }
        end
      end
    end
    threads.each(&:join)

    assert_operator max_seen, :<=, limit,
                    "atomicity breached: saw #{max_seen} concurrent holders for a limit of #{limit}"
    assert_equal 0, over_limit, "no acquire should time out with a 15s wait (#{over_limit} did)"
    assert_equal THREADS * PER_THREAD, acquired, 'every acquire should eventually succeed'
    assert_equal 0, limiter.size, 'every slot released at the end'
  end

  # All limiter acquire/release scripts ship as files, get a precomputed SHA,
  # and run via EVALSHA (with NOSCRIPT recovery) — never re-uploaded per call.
  def test_all_limiter_lua_scripts_are_evalsha_cached
    %i[limiter_concurrent_acquire limiter_concurrent_release limiter_bucket_acquire
       limiter_window_acquire limiter_leaky_acquire limiter_points_acquire
       limiter_points_refund].each do |name|
      assert Wurk::Lua::SCRIPTS.key?(name), "missing Lua script #{name}"
      assert_match(/\A[0-9a-f]{40}\z/, Wurk::Lua::SHAS[name], "no precomputed SHA for #{name}")
    end

    # EVALSHA path resolves even after a SCRIPT FLUSH (NOSCRIPT → reload).
    @pool.with { |c| c.call('SCRIPT', 'FLUSH') }
    l = Wurk::Limiter.concurrent("flush-#{@suffix}", 1)
    ran = false
    l.within_limit { ran = true }

    assert ran, 'acquire should recover from a flushed script cache'
  ensure
    Wurk::Limiter.concurrent("flush-#{@suffix}", 1).delete
  end
end
