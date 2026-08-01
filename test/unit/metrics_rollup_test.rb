# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'
require 'wurk/metrics/rollup'
require 'wurk/metrics/query'

# The rollup writes cluster-total buckets keyed only by time (`jr|<bucket>|<epoch>`),
# so — unlike the per-class history buckets — there's no class field to isolate
# parallel forks. Each test instead picks a unique minute-aligned epoch from a
# wide random range so its source `j|` bucket and its `jr|` totals never collide
# with another fork, then DELs exactly those keys on teardown.
class MetricsRollupTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    # Per-test isolation keyed to PID:object_id (the parallel-runner guideline):
    # the pid gives each fork a disjoint minute block, object_id separates tests
    # within a fork. Whole-key writes + the teardown DEL make object_id reuse
    # after GC harmless here — unlike the shared-field history buckets, which
    # need SecureRandom to avoid inheriting a recycled id's field.
    @epoch_min = ((2_000_000_000 + ((Process.pid % 100_000) * 100_000) + (object_id % 100_000)) / 60) * 60
    @at = ::Time.at(@epoch_min).utc
    @klass = "RollupJob-#{SecureRandom.hex(6)}"
    @rollup = Wurk::Metrics::Rollup.new(Wurk.configuration)
  end

  def teardown
    Wurk.redis do |c|
      keys = [Wurk::Metrics::History.minute_key(@at)]
      Wurk::Metrics::Rollup::BUCKETS.each do |bucket, (step, _ttl)|
        keys << Wurk::Metrics::Rollup.bucket_key(bucket, (@epoch_min / step) * step)
      end
      c.call('DEL', *keys)
    end
  ensure
    super
  end

  def test_roll_writes_each_total_bucket_from_the_source_minute
    seed_minute(processed: 10, failed: 2, ms: 500)
    @rollup.roll(@at + 60)
    expected = { 'p' => 10, 'f' => 2, 'ms' => 500 }

    assert_equal expected, bucket_hash('1m')
    assert_equal expected, bucket_hash('5m')
    assert_equal expected, bucket_hash('1h')
  end

  def test_roll_sums_across_job_classes
    seed_minute(processed: 10, failed: 2, ms: 500)
    Wurk.redis { |c| c.call('HSET', Wurk::Metrics::History.minute_key(@at), 'OtherJob|p', 5, 'OtherJob|ms', 250) }
    @rollup.roll(@at + 60)

    assert_equal({ 'p' => 15, 'f' => 2, 'ms' => 750 }, bucket_hash('1m'))
  end

  def test_roll_is_idempotent_across_repeated_passes
    seed_minute(processed: 7, failed: 1, ms: 300)
    3.times { @rollup.roll(@at + 60) }

    assert_equal({ 'p' => 7, 'f' => 1, 'ms' => 300 }, bucket_hash('1h'))
  end

  def test_roll_sets_per_bucket_retention_ttls
    seed_minute(processed: 1, failed: 0, ms: 10)
    @rollup.roll(@at + 60)

    Wurk::Metrics::Rollup::BUCKETS.each do |bucket, (step, ttl)|
      actual = Wurk.redis { |c| c.call('TTL', Wurk::Metrics::Rollup.bucket_key(bucket, (@epoch_min / step) * step)) }

      assert_operator actual, :>, ttl - 120, "#{bucket} ttl too low"
      assert_operator actual, :<=, ttl, "#{bucket} ttl too high"
    end
  end

  def test_roll_skips_empty_minutes
    @rollup.roll(@at + 60) # no source data seeded

    assert_empty bucket_hash('1m')
  end

  def test_tick_writes_when_leader
    seed_minute(processed: 9, failed: 0, ms: 90)
    @rollup.define_singleton_method(:leader?) { true }
    @rollup.tick(now: @at + 60)

    assert_equal 9, bucket_hash('1m')['p']
  end

  def test_tick_is_leader_gated
    seed_minute(processed: 9, failed: 0, ms: 90)
    @rollup.define_singleton_method(:leader?) { false }
    @rollup.tick(now: @at + 60)

    assert_empty bucket_hash('1m')
  end

  # --- background thread loop (start/terminate) -------------------------

  # Exercises the `until @done` loop body (tick is invoked by the spawned
  # thread, not the caller). A 0.01s interval + leader stub + poll keeps it
  # deterministic without a fixed sleep.
  # rubocop:disable Metrics/AbcSize
  def test_start_loop_ticks_until_terminated
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:metrics_rollup_interval] = 0.01
    rollup = Wurk::Metrics::Rollup.new(config)
    rollup.define_singleton_method(:leader?) { true }
    rollup.define_singleton_method(:roll) do |_now = ::Time.now|
      @ticks = (@ticks || 0) + 1
    end

    rollup.start
    poll_until(2.0) { rollup.instance_variable_get(:@ticks).to_i.positive? }
    rollup.terminate

    assert_operator rollup.instance_variable_get(:@ticks).to_i, :>, 0
  end
  # rubocop:enable Metrics/AbcSize

  # terminate is a barrier: the launcher releases the cluster lock right after
  # it returns, so a roll still in flight would write the same buckets as the
  # next leader's first one.
  def test_terminate_joins_and_clears_the_thread
    rollup = loop_rollup
    rollup.define_singleton_method(:leader?) { false }

    thread = rollup.start
    rollup.terminate

    refute_predicate thread, :alive?, 'terminate must join the rollup thread'
    assert_nil rollup.instance_variable_get(:@thread)
  end

  # A cleared @thread would be pointless if the timer stayed terminated —
  # start has to re-arm it, not spawn a thread that exits immediately.
  def test_start_after_terminate_rolls_again
    rollup = loop_rollup
    rollup.define_singleton_method(:leader?) { true }
    rollup.define_singleton_method(:roll) { |_now = ::Time.now| @ticks = (@ticks || 0) + 1 }

    rollup.start
    rollup.terminate
    rollup.instance_variable_set(:@ticks, 0)
    rollup.start
    poll_until(2.0) { rollup.instance_variable_get(:@ticks).positive? }

    assert_operator rollup.instance_variable_get(:@ticks), :>, 0
  ensure
    rollup&.terminate
  end

  # `TimerLoop#wait` short-circuits the ConditionVariable wait once terminated
  # (the `unless @done` else branch) so terminate-then-wait returns at once.
  # Mutex/CV mechanics live in Wurk::TimerLoop now (test/unit/timer_loop_test.rb);
  # this just confirms Rollup wires #terminate through to its @timer.
  def test_terminate_makes_timer_wait_return_immediately
    @rollup.terminate

    completed = false
    t = Thread.new do
      @rollup.instance_variable_get(:@timer).wait
      completed = true
    end
    t.join(2.0)

    assert completed, 'wait must return immediately once terminated'
  ensure
    t&.kill
  end

  # --- minute_total field parsing ---------------------------------------

  # A source field whose kind isn't p/f/ms (or has no kind) is ignored — the
  # `total.key?` guard's else side. Seeding a `Klass|x` field must not blow up
  # the totals or raise.
  def test_minute_total_ignores_unknown_kind_fields
    seed_minute(processed: 3, failed: 0, ms: 30)
    Wurk.redis do |c|
      c.call('HSET', Wurk::Metrics::History.minute_key(@at),
             "#{@klass}|x", 999, 'nopipe', 7)
    end
    @rollup.roll(@at + 60)

    assert_equal({ 'p' => 3, 'f' => 0, 'ms' => 30 }, bucket_hash('1m'))
  end

  # ---- Query.history reader ------------------------------------------------

  def test_history_reader_returns_gap_filled_series
    seed_minute(processed: 4, failed: 1, ms: 40)
    @rollup.roll(@at + 60)
    series = Wurk::Metrics::Query.history('1m', 300, now: @at + 120)
    point = series.find { |row| row[:at] == @epoch_min }

    assert_equal({ at: @epoch_min, p: 4, f: 1, ms: 40 }, point)
    assert_equal 5, series.size
    assert(series.all? { |row| row[:p].is_a?(Integer) })
  end

  def test_history_reader_rejects_unknown_bucket
    assert_raises(ArgumentError) { Wurk::Metrics::Query.history('2m', 300) }
  end

  def test_history_reader_clamps_window_to_retention
    series = Wurk::Metrics::Query.history('1m', 48 * 3600, now: @at + 120)

    assert_operator series.size, :<=, 24 * 60
  end

  private

  # A Rollup on a throwaway config with a tick interval short enough that the
  # spawned loop body runs within the test window.
  def loop_rollup
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:metrics_rollup_interval] = 0.01
    Wurk::Metrics::Rollup.new(config)
  end

  def poll_until(timeout)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    sleep(0.005) until yield || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
  end

  def seed_minute(processed:, failed:, ms:)
    Wurk.redis do |c|
      c.call('HSET', Wurk::Metrics::History.minute_key(@at),
             "#{@klass}|p", processed, "#{@klass}|f", failed, "#{@klass}|ms", ms)
    end
  end

  def bucket_hash(bucket)
    step = Wurk::Metrics::Rollup::BUCKETS[bucket][0]
    raw = Wurk.redis { |c| c.call('HGETALL', Wurk::Metrics::Rollup.bucket_key(bucket, (@epoch_min / step) * step)) }
    raw = raw.each_slice(2).to_h if raw.is_a?(::Array)
    raw.transform_values(&:to_i)
  end
end
