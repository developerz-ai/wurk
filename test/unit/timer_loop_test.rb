# frozen_string_literal: true

require_relative '../test_helper'

# Pins Wurk::TimerLoop, the mutex/CV "tick every N seconds until stopped"
# primitive shared by History, Metrics::Rollup and Metrics::QueueRollup
# (previously duplicated in each).
class TimerLoopTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_run_waits_before_first_tick
    timer = Wurk::TimerLoop.new(0.05)
    ticks = []

    thread = Thread.new do
      timer.run do
        ticks << :tick
        timer.terminate
      end
    end
    sleep(0.01)

    assert_empty ticks, 'must not tick before the first interval elapses'
    thread.join(2.0)

    assert_equal [:tick], ticks
  end

  def test_run_ticks_repeatedly_until_terminated
    timer = Wurk::TimerLoop.new(0.01)
    ticks = 0

    thread = Thread.new { timer.run { ticks += 1 } }
    poll_until(2.0) { ticks >= 3 }
    timer.terminate
    thread.join(2.0)

    assert_operator ticks, :>=, 3
  end

  # terminate signals the CV, so a thread blocked in #wait returns immediately
  # rather than waiting out the full interval.
  def test_terminate_wakes_a_blocked_wait
    timer = Wurk::TimerLoop.new(60)
    started = false
    completed = false

    thread = Thread.new do
      started = true
      timer.wait
      completed = true
    end
    poll_until(2.0) { started }
    timer.terminate
    thread.join(2.0)

    assert completed, 'terminate must wake a thread blocked in #wait'
  end

  # Once @done is set, #wait short-circuits (the `unless @done` branch)
  # instead of blocking on the ConditionVariable at all.
  def test_wait_returns_immediately_once_done
    timer = Wurk::TimerLoop.new(60)
    timer.terminate

    completed = false
    thread = Thread.new do
      timer.wait
      completed = true
    end
    thread.join(2.0)

    assert completed, 'wait must return immediately once terminated'
  end

  def test_run_never_yields_once_terminated_before_start
    timer = Wurk::TimerLoop.new(60)
    timer.terminate

    ticked = false
    thread = Thread.new { timer.run { ticked = true } }
    thread.join(2.0)

    refute ticked, 'run must not tick if already terminated before the first wait'
  end

  private

  def poll_until(timeout)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    sleep(0.005) until yield || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
  end
end
