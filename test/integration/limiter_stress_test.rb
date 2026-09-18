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

  def test_1000_concurrent_acquires_never_exceed_the_limit
    limit = 5
    limiter = Wurk::Limiter.concurrent("c-#{@suffix}", limit, wait_timeout: 15, lock_timeout: 30)
    run = hammer(limiter, threads: THREADS, per_thread: PER_THREAD)

    assert_operator run.max_seen, :<=, limit,
                    "atomicity breached: saw #{run.max_seen} concurrent holders for a limit of #{limit}"
    assert_equal THREADS * PER_THREAD, run.acquired + run.refused,
                 "every attempt is accounted for: #{run.acquired} acquired + #{run.refused} refused"
    assert_equal 0, limiter.size, 'every slot released at the end'
  end

  # The same three invariants against a limiter that CANNOT serve a waiter:
  # every slot is held for the whole run, so every acquire below refuses.
  #
  # This is the case that separates what this file tests from what it used to
  # MEASURE. The old assertion `over_limit == 0` — "no acquire should time out
  # with a 15s wait" — is red here BY CONSTRUCTION while the limiter is behaving
  # perfectly, which is the same reason it went red on a loaded runner with
  # nothing held at all (wurk#522, developerz-ai/developerz.ai#4386): a wait
  # budget is a claim about the HOST's speed, not about the acquire script's
  # atomicity. What survives starvation is what this suite is for — the limit is
  # never breached, every attempt is accounted for as acquired or refused, and a
  # refusal leaks no slot.
  def test_a_fully_held_limiter_refuses_without_breaching_or_leaking_a_slot
    limit = 3
    held = Wurk::Limiter.concurrent("c-#{@suffix}", limit, wait_timeout: 15, lock_timeout: 30)
    release = ::Queue.new
    holders = Array.new(limit) { ::Thread.new { held.within_limit { release.pop } } }

    assert wait_until { held.size == limit }, "expected #{limit} slots held, saw #{held.size}"

    # A wait budget SHORTER than the default, never longer: this case must reach
    # the refusal quickly and must not become another thing that waits on the host.
    starved = Wurk::Limiter.concurrent("c-#{@suffix}", limit, wait_timeout: 0.5, lock_timeout: 30)
    run = hammer(starved, threads: 10, per_thread: 1)

    assert_equal 0, run.acquired, 'a fully held limiter admits nobody'
    assert_equal 10, run.refused, 'every starved acquire refuses rather than vanishing'
    assert_operator run.max_seen, :<=, limit,
                    "atomicity breached under starvation: saw #{run.max_seen} holders for a limit of #{limit}"

    limit.times { release.push(:go) }
    holders.each(&:join)

    assert_equal 0, held.size, 'a refused acquire leaks no slot'
  end

  # Every limiter script — acquire, release and the read-only window probe —
  # ships as a file, gets a precomputed SHA, and runs via EVALSHA (with NOSCRIPT
  # recovery) — never re-uploaded per call.
  def test_all_limiter_lua_scripts_are_evalsha_cached
    %i[limiter_concurrent_acquire limiter_concurrent_release limiter_bucket_acquire
       limiter_window_acquire limiter_window_status limiter_leaky_acquire
       limiter_points_acquire limiter_points_refund].each do |name|
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
    # The EVALSHA cache is SERVER-wide, not per-DB, so this flush is visible to
    # every parallel_fork worker. Reload the moment the assertion below is done
    # so the window a sibling suite can be caught in is a handful of commands
    # rather than the rest of this test. (ClientBatchPipelineTest, which counts
    # pipelines, detects the interference and skips rather than failing.)
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
    Wurk::Limiter.concurrent("flush-#{@suffix}", 1).delete
  end

  private

  # What one contention run observed: the most holders ever inside the block at
  # once, and how each attempt ended. `acquired + refused` is every attempt made
  # — an acquire that neither ran nor refused would be a lost attempt, which is
  # the failure this count exists to catch.
  Run = ::Struct.new(:max_seen, :acquired, :refused)

  # Hammer one limiter from `threads` threads and report the run. No deadline
  # and no clock assertion: the caller's `wait_timeout` decides when an acquire
  # gives up, and `Run` records that it gave up rather than failing the test for
  # it.
  def hammer(limiter, threads:, per_thread:)
    mutex = ::Mutex.new
    in_flight = 0
    run = Run.new(0, 0, 0)

    workers = Array.new(threads) do
      ::Thread.new do
        per_thread.times do
          limiter.within_limit do
            mutex.synchronize do
              in_flight += 1
              run.max_seen = in_flight if in_flight > run.max_seen
              run.acquired += 1
            end
            sleep 0.002 # widen the window so any non-atomic slip would overlap
            mutex.synchronize { in_flight -= 1 }
          end
        rescue Wurk::Limiter::OverLimit
          mutex.synchronize { run.refused += 1 }
        end
      end
    end
    workers.each(&:join)
    run
  end

  # Poll for a condition the limiter reaches through OTHER threads. The deadline
  # is a stop, not an assertion: every caller asserts on the condition itself, so
  # a slow host lengthens the poll and never changes the verdict.
  def wait_until(timeout: 15, interval: 0.02)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    until ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) >= deadline
      return true if yield

      sleep interval
    end
    yield
  end
end
