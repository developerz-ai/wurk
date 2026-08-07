# frozen_string_literal: true

require_relative '../test_helper'

# Pure in-memory state machine — no Redis, no process globals, so every test
# owns its own accumulator.
class MetricsAccumulatorTest < Wurk::Test::UnitCase
  parallelize_me!

  MINUTE = 29_712_337 # arbitrary; only its identity as a bucket key matters

  def setup
    super
    @acc = Wurk::Metrics::Accumulator.new
  end

  def test_starts_empty
    assert_predicate @acc, :empty?
    assert_empty @acc.drain
  end

  def test_add_folds_successes_failures_and_runtime
    3.times { add(ms: 10) }
    2.times { add(ms: 5, success: false) }

    assert_equal({ nil => { MINUTE => { 'FooJob' => [3, 2, 40] } } }, @acc.drain)
  end

  # A multi-capsule process records through more than one pool, and each pool's
  # counts have to flush through the pool that capsule's jobs ran on.
  def test_add_keys_by_pool
    pool = Object.new
    add
    add(pool: pool)

    assert_equal [nil, pool], @acc.drain.keys
  end

  def test_add_keys_by_minute_and_class
    add
    add(klass: 'BarJob')
    add(minute: MINUTE + 1)

    drained = @acc.drain[nil]

    assert_equal [MINUTE, MINUTE + 1], drained.keys
    assert_equal %w[FooJob BarJob], drained[MINUTE].keys
  end

  # Recording must never block behind a flush's round trip: the drain hands the
  # tree over and installs a fresh one, so an add racing the write lands in the
  # next window rather than in the batch already being sent.
  def test_drain_hands_over_the_tree_and_starts_a_fresh_one
    @acc.add(nil, 'FooJob', MINUTE, 7, true)
    drained = @acc.drain

    assert_predicate @acc, :empty?

    @acc.add(nil, 'FooJob', MINUTE, 1, true)

    assert_equal [1, 0, 7], drained[nil][MINUTE]['FooJob']
  end

  # A failed write puts its counts back, and the counts that arrived while it
  # was in flight are still there — so the retry has to add to them, not
  # overwrite them.
  def test_merge_back_adds_to_what_arrived_during_the_flush
    @acc.add(nil, 'FooJob', MINUTE, 10, true)
    failed = @acc.drain
    @acc.add(nil, 'FooJob', MINUTE, 3, false)
    @acc.add(nil, 'BarJob', MINUTE, 1, true)

    @acc.merge_back(nil, failed[nil])

    assert_equal({ 'FooJob' => [1, 1, 13], 'BarJob' => [1, 0, 1] }, @acc.drain[nil][MINUTE])
  end

  def test_merge_back_restores_a_pool_and_minute_that_no_longer_exist
    @acc.add(nil, 'FooJob', MINUTE, 4, true)
    failed = @acc.drain

    @acc.merge_back(nil, failed[nil])

    assert_equal failed, @acc.drain
  end

  # An outage that outlives the cap must not grow a structure the job hot path
  # feeds. The newest buckets are the ones the dashboard is still drawing, so
  # they are the ones that survive.
  def test_merge_back_caps_retained_minutes_and_keeps_the_newest
    cap = Wurk::Metrics::Accumulator::MAX_RETAINED_MINUTES
    (cap + 10).times { |i| add(minute: MINUTE + i) }
    failed = @acc.drain

    @acc.merge_back(nil, failed[nil])

    assert_equal(((MINUTE + 10)..(MINUTE + cap + 9)).to_a, @acc.drain[nil].keys.sort)
  end

  private

  def add(pool: nil, klass: 'FooJob', minute: MINUTE, ms: 1, success: true)
    @acc.add(pool, klass, minute, ms, success)
  end
end
