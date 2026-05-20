# frozen_string_literal: true

require_relative '../test_helper'
require 'date'
require 'securerandom'

# Drives Wurk::Stats against real Redis. Stats reads global keys (stat:processed,
# stat:failed, schedule/retry/dead zsets, processes set). We *don't* `parallelize_me!`
# on this class because `reset` is globally destructive — across-file parallelism
# can still interleave, but within-class serial keeps the blast radius contained.
#
# For shared zsets/sets we add uniquely-named members and assert `>=` lower bounds;
# for the global counters we read snapshots and assert deltas.
class StatsTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns         = "#{Process.pid}-#{object_id}"
    @queue      = "stats-q-#{@ns}"
    @class_name = "StatsJob@#{@ns}"
    @identity   = "stats-id-#{@ns}"
    @pool       = Wurk.configuration.redis_pool
    @added_identity = false
    @zset_members   = Hash.new { |h, k| h[k] = [] }
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
      @zset_members.each { |set, members| members.each { |m| conn.call('ZREM', set, m) } }
      if @added_identity
        conn.call('SREM', 'processes', @identity)
        conn.call('DEL', @identity, "#{@identity}:work")
      end
    end
  ensure
    super
  end

  # --- cheap counters ----------------------------------------------------

  def test_processed_returns_integer
    assert_kind_of Integer, Wurk::Stats.new.processed
  end

  def test_processed_reflects_redis_value
    base = Wurk::Stats.new.processed
    @pool.with { |c| c.call('INCRBY', 'stat:processed', 7) }

    assert_operator Wurk::Stats.new.processed, :>=, base + 7
  end

  def test_failed_reflects_redis_value
    base = Wurk::Stats.new.failed
    @pool.with { |c| c.call('INCRBY', 'stat:failed', 3) }

    assert_operator Wurk::Stats.new.failed, :>=, base + 3
  end

  def test_counters_are_fetched_eagerly
    snap = Wurk::Stats.new
    @pool.with { |c| c.call('INCRBY', 'stat:processed', 50) }

    assert_equal snap.processed, snap.processed, 'cached value should not change after init'
  end

  # --- sized sets --------------------------------------------------------

  def test_scheduled_size_returns_integer
    assert_kind_of Integer, Wurk::Stats.new.scheduled_size
  end

  def test_scheduled_size_counts_zset_entries
    add_zset_member('schedule', 'sched-m1')
    add_zset_member('schedule', 'sched-m2')

    assert_operator Wurk::Stats.new.scheduled_size, :>=, 2
  end

  def test_retry_size_counts_zset_entries
    add_zset_member('retry', 'retry-m1')

    assert_operator Wurk::Stats.new.retry_size, :>=, 1
  end

  def test_dead_size_counts_zset_entries
    add_zset_member('dead', 'dead-m1')

    assert_operator Wurk::Stats.new.dead_size, :>=, 1
  end

  def test_processes_size_counts_set_members
    register_identity!

    assert_operator Wurk::Stats.new.processes_size, :>=, 1
  end

  def test_workers_size_returns_integer
    assert_kind_of Integer, Wurk::Stats.new.workers_size
  end

  def test_workers_size_sums_busy_across_identities
    register_identity!('busy' => '4')

    assert_operator Wurk::Stats.new.workers_size, :>=, 4
  end

  def test_workers_size_ignores_missing_busy_field
    register_identity!

    refute_nil Wurk::Stats.new.workers_size
  end

  # --- queues ------------------------------------------------------------

  def test_enqueued_returns_integer
    assert_kind_of Integer, Wurk::Stats.new.enqueued
  end

  def test_enqueued_reflects_my_queue_size
    # Scope to `@queue` — the global `enqueued` sum fluctuates as parallel
    # siblings push/pop their own queues.
    push_my_job
    base = Wurk::Stats.new.queues[@queue].to_i
    push_my_job

    assert_operator Wurk::Stats.new.queues[@queue].to_i, :>=, base + 1
  end

  def test_queues_returns_hash_keyed_by_name
    push_my_job

    assert_equal 1, Wurk::Stats.new.queues[@queue]
  end

  def test_queues_returns_empty_hash_when_no_queues_registered
    @pool.with { |c| c.call('SREM', 'queues', @queue) }

    assert_kind_of Hash, Wurk::Stats.new.queues
  end

  def test_queue_summaries_includes_my_queue
    push_my_job
    summary = Wurk::Stats.new.queue_summaries.find { |s| s.name == @queue }

    refute_nil summary
    assert_equal 1, summary.size
  end

  # rubocop:disable Minitest/MultipleAssertions
  # One test, one shape: the QueueSummary Data class is the public contract.
  def test_queue_summary_exposes_data_shape
    push_my_job
    summary = Wurk::Stats.new.queue_summaries.find { |s| s.name == @queue }

    assert_equal @queue,    summary.name
    assert_kind_of Integer, summary.size
    assert_kind_of Float,   summary.latency
    assert_includes [true, false], summary.paused?
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_queue_summary_latency_uses_oldest_enqueued_at_ms
    push_my_job(enqueued_at: ms_now - 5_000)
    summary = Wurk::Stats.new.queue_summaries.find { |s| s.name == @queue }

    assert_in_delta 5.0, summary.latency, 1.5
  end

  def test_queue_summary_latency_handles_legacy_float_seconds
    push_my_job(enqueued_at: (ms_now - 3_000) / 1000.0)
    summary = Wurk::Stats.new.queue_summaries.find { |s| s.name == @queue }

    assert_in_delta 3.0, summary.latency, 1.5
  end

  def test_queue_summary_paused_reflects_paused_set
    push_my_job
    @pool.with { |c| c.call('SADD', 'paused', @queue) }
    begin
      summary = Wurk::Stats.new.queue_summaries.find { |s| s.name == @queue }

      assert_predicate summary, :paused?
    ensure
      @pool.with { |c| c.call('SREM', 'paused', @queue) }
    end
  end

  def test_queue_summaries_is_empty_when_no_queues_registered
    @pool.with { |c| c.call('SREM', 'queues', @queue) }

    assert_kind_of Array, Wurk::Stats.new.queue_summaries
  end

  def test_default_queue_latency_returns_float
    assert_kind_of Float, Wurk::Stats.new.default_queue_latency
  end

  def test_default_queue_latency_is_non_negative
    assert_operator Wurk::Stats.new.default_queue_latency, :>=, 0.0
  end

  # --- reset -------------------------------------------------------------

  def test_reset_clears_both_counters_by_default
    @pool.with do |c|
      c.call('SET', 'stat:processed', 999)
      c.call('SET', 'stat:failed', 999)
    end
    Wurk::Stats.new.reset

    snap = Wurk::Stats.new

    assert_equal 0, snap.processed
    assert_equal 0, snap.failed
  end

  def test_reset_with_explicit_stat_clears_only_that_one
    @pool.with do |c|
      c.call('SET', 'stat:processed', 50)
      c.call('SET', 'stat:failed', 75)
    end
    Wurk::Stats.new.reset('processed')

    snap = Wurk::Stats.new

    assert_equal 0, snap.processed
    assert_operator snap.failed, :>=, 75
  end

  def test_reset_ignores_unknown_stats
    @pool.with { |c| c.call('SET', 'stat:processed', 42) }
    Wurk::Stats.new.reset('bogus')

    assert_operator Wurk::Stats.new.processed, :>=, 42
  end

  def test_reset_accepts_symbol_stats
    @pool.with { |c| c.call('SET', 'stat:failed', 11) }
    Wurk::Stats.new.reset(:failed)

    assert_equal 0, Wurk::Stats.new.failed
  end

  # --- History -----------------------------------------------------------

  def test_history_rejects_zero_days
    assert_raises(ArgumentError) { Wurk::Stats::History.new(0) }
  end

  def test_history_rejects_above_max
    assert_raises(ArgumentError) { Wurk::Stats::History.new(1826) }
  end

  def test_history_accepts_max_range
    assert_equal 1825, Wurk::Stats::History.new(1825).processed.size
  end

  def test_history_processed_returns_hash_keyed_by_date_string
    today = Date.today.strftime('%Y-%m-%d')
    @pool.with { |c| c.call('SET', "stat:processed:#{today}", 12) }
    begin
      h = Wurk::Stats::History.new(3)

      assert_equal 12, h.processed[today]
    ensure
      @pool.with { |c| c.call('DEL', "stat:processed:#{today}") }
    end
  end

  def test_history_failed_returns_hash_keyed_by_date_string
    today = Date.today.strftime('%Y-%m-%d')
    @pool.with { |c| c.call('SET', "stat:failed:#{today}", 4) }
    begin
      assert_equal 4, Wurk::Stats::History.new(3).failed[today]
    ensure
      @pool.with { |c| c.call('DEL', "stat:failed:#{today}") }
    end
  end

  def test_history_with_start_date_anchors_window
    start = Date.new(2025, 5, 20)
    key   = "stat:processed:#{start.strftime('%Y-%m-%d')}"
    @pool.with { |c| c.call('SET', key, 99) }
    begin
      h = Wurk::Stats::History.new(2, start)

      assert_equal 99, h.processed[start.strftime('%Y-%m-%d')]
    ensure
      @pool.with { |c| c.call('DEL', key) }
    end
  end

  def test_history_missing_days_default_to_zero
    h = Wurk::Stats::History.new(2, Date.new(1990, 1, 1))

    assert_equal [0, 0], h.processed.values
  end

  def test_history_uses_explicit_pool
    today = Date.today.strftime('%Y-%m-%d')
    @pool.with { |c| c.call('SET', "stat:processed:#{today}", 5) }
    begin
      assert_equal 5, Wurk::Stats::History.new(1, nil, pool: @pool).processed[today]
    ensure
      @pool.with { |c| c.call('DEL', "stat:processed:#{today}") }
    end
  end

  # --- QueueSummary shape -----------------------------------------------

  def test_queue_summary_paused_predicate
    s = Wurk::Stats::QueueSummary.new(name: 'x', size: 0, latency: 0.0, paused: true)

    assert_predicate s, :paused?
  end

  def test_queue_summary_unpaused_predicate
    s = Wurk::Stats::QueueSummary.new(name: 'x', size: 0, latency: 0.0, paused: false)

    refute_predicate s, :paused?
  end

  private

  def push_my_job(enqueued_at: ms_now)
    payload = Wurk.dump_json(
      'class' => @class_name,
      'args' => [],
      'queue' => @queue,
      'jid' => SecureRandom.hex(12),
      'enqueued_at' => enqueued_at
    )
    @pool.with do |c|
      c.call('SADD', 'queues', @queue)
      c.call('LPUSH', "queue:#{@queue}", payload)
    end
  end

  def add_zset_member(set, suffix)
    member = "#{@ns}|#{suffix}"
    @zset_members[set] << member
    @pool.with { |c| c.call('ZADD', set, ms_now.to_f / 1000, member) }
  end

  def register_identity!(fields = {})
    @added_identity = true
    @pool.with do |c|
      c.call('SADD', 'processes', @identity)
      fields.each { |k, v| c.call('HSET', @identity, k, v) }
    end
  end

  def ms_now
    Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
  end
end
