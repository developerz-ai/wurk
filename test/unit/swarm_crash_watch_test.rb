# frozen_string_literal: true

require_relative '../test_helper'

class SwarmCrashWatchTest < Wurk::Test::UnitCase
  parallelize_me!

  def watch(exit_after: 100) = Wurk::Swarm::CrashWatch.new(exit_after: exit_after, young_within: 60)

  def test_due_only_when_every_slot_has_crashed_young_for_the_whole_window
    w = watch
    w.record(0, lifetime: 1, now: 0)

    refute w.due?([0, 1], 200), 'a slot with no crash streak keeps the fleet alive'
    w.record(1, lifetime: 1, now: 150)

    refute w.due?([0, 1], 200), 'the second slot has not been crashing for the window yet'
    assert w.due?([0, 1], 250)
  end

  def test_a_child_that_outlives_the_young_window_ends_the_streak
    w = watch
    w.record(0, lifetime: 1, now: 0)
    w.settled(0, 30)

    assert w.due?([0], 100), 'a child still young settles nothing'
    w.settled(0, 61)

    refute w.due?([0], 200)
  end

  def test_a_mature_crash_starts_nothing
    w = watch

    assert_equal 1, w.record(0, lifetime: 61, now: 0)
    refute w.due?([0], 1000)
  end

  def test_an_excused_crash_clears_the_streak
    w = watch
    w.record(0, lifetime: 1, now: 0)

    assert_equal 0, w.record(0, lifetime: 1, now: 50, excused: true)
    refute w.due?([0], 200)
  end

  def test_streak_counts_consecutive_young_crashes
    w = watch

    streaks = (1..3).map { |n| w.record(0, lifetime: 1, now: n) }

    assert_equal [1, 2, 3], streaks
  end

  def test_nil_exit_after_never_comes_due
    w = watch(exit_after: nil)
    w.record(0, lifetime: 1, now: 0)

    refute w.due?([0], 1_000_000)
    refute w.due?([], 0)
  end

  def test_rearm_restarts_the_window
    w = watch
    w.record(0, lifetime: 1, now: 0)
    w.rearm(150)

    refute w.due?([0], 200)
    assert w.due?([0], 250)
  end

  def test_max_streak_is_the_longest_live_streak
    w = watch

    assert_equal 0, w.max_streak
    2.times { |i| w.record(0, lifetime: 1, now: i) }
    w.record(1, lifetime: 1, now: 0)

    assert_equal 2, w.max_streak
    w.settled(0, 61)

    assert_equal 1, w.max_streak
  end
end
