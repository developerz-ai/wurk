# frozen_string_literal: true

require_relative '../test_helper'

# The two rules a teardown obeys: it runs exactly once, and it never waits on a
# thread without a bound.
class ShutdownGateTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @gate = Wurk::ShutdownGate.new
    @threads = []
  end

  def teardown
    @threads.each { |t| t.kill.join(1) }
  ensure
    super
  end

  # --- run: single-shot -------------------------------------------------

  def test_run_yields_to_the_first_caller
    ran = 0

    @gate.run { ran += 1 }

    assert_equal 1, ran
  end

  def test_run_yields_only_once_across_sequential_calls
    ran = 0

    3.times { @gate.run { ran += 1 } }

    assert_equal 1, ran
  end

  # N concurrent TERMs used to mean N teardowns racing each other through the
  # same components. Exactly one must win, however many arrive together.
  def test_concurrent_callers_yield_exactly_once
    ran = Queue.new
    release = Queue.new
    winner = claim_and_hold(ran, release)

    losers = Array.new(4) { spawn_thread { @gate.run { ran << true } } }
    release << true
    [winner, *losers].each { |t| t.join(5) }

    assert_equal 1, ran.size
  end

  # A caller that asked for the shutdown must not return while the process is
  # still up — otherwise an embedded host's `stop` hands control back mid-drain.
  def test_a_later_caller_blocks_until_the_teardown_finishes
    finished = false
    release = Queue.new
    entered = Queue.new
    owner = spawn_thread do
      @gate.run do
        entered << true
        release.pop
        finished = true
      end
    end
    entered.pop

    waiter = spawn_thread { @gate.run { nil } }

    refute waiter.join(0.1), 'a second caller must not return while the teardown is still running'
    release << true
    owner.join(5)
    waiter.join(5)

    assert finished
  end

  def test_a_caller_after_the_teardown_returns_immediately
    @gate.run { nil }

    assert spawn_thread { @gate.run { flunk 'must not re-run the teardown' } }.join(5)
  end

  # The owner re-entering (a `:shutdown` hook that calls stop) cannot wait on a
  # teardown it is inside of.
  def test_the_owner_re_entering_does_not_deadlock
    reentered = false

    @gate.run do
      @gate.run { flunk 'a re-entrant call must not run the teardown again' }
      reentered = true
    end

    assert reentered
  end

  def test_waiters_are_released_when_the_teardown_raises
    owner = spawn_thread do
      @gate.run { raise 'teardown blew up' }
    rescue RuntimeError
      :raised
    end

    assert_equal :raised, owner.value, 'the failure belongs to the caller that owns the teardown'
    assert spawn_thread { @gate.run { nil } }.join(5), 'a failed teardown must still release its waiters'
  end

  def test_run_returns_nil_to_a_caller_that_did_not_claim
    @gate.run { :whatever }

    assert_nil(@gate.run { :whatever })
  end

  # --- runner -----------------------------------------------------------

  def test_runner_spawns_once_and_hands_the_same_thread_back
    spawned = 0
    first = @gate.runner { spawn_thread { spawned += 1 } }
    second = @gate.runner { spawn_thread { spawned += 1 } }
    first.join(5)

    assert_same first, second
    assert_equal 1, spawned
  end

  # --- join_within ------------------------------------------------------

  def test_join_within_returns_once_every_thread_is_done
    threads = Array.new(3) { spawn_thread { nil } }

    @gate.join_within(threads, monotonic + 5)

    threads.each { |t| refute_predicate t, :alive? }
  end

  # One shared budget, not one per thread: N wedged capsules must cost the
  # budget once, not N times.
  def test_join_within_shares_one_budget_across_every_thread
    gate = Queue.new
    threads = Array.new(3) { spawn_thread { gate.pop } }

    started = monotonic
    @gate.join_within(threads, started + 0.3)
    elapsed = monotonic - started

    assert_operator elapsed, :<, 1.5, "one shared budget, got #{elapsed}s for 3 wedged threads"
    threads.each { |t| assert_predicate t, :alive?, 'a wedged thread is left running, not killed' }
  ensure
    3.times { gate << true }
  end

  def test_join_within_does_not_wait_when_the_budget_is_already_spent
    gate = Queue.new
    thread = spawn_thread { gate.pop }

    started = monotonic
    @gate.join_within([thread], monotonic - 10)

    assert_operator monotonic - started, :<, 0.5, 'a spent budget must poll, not wait'
  ensure
    gate << true
  end

  private

  # Claims the gate on a background thread and parks inside the teardown until
  # `release` is fed, so the assertions run against a drain that is in flight.
  def claim_and_hold(ran, release)
    entered = Queue.new
    thread = spawn_thread do
      @gate.run do
        entered << true
        ran << true
        release.pop
      end
    end
    entered.pop
    thread
  end

  def monotonic
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def spawn_thread(&)
    thread = Thread.new(&)
    thread.report_on_exception = false
    @threads << thread
    thread
  end
end
