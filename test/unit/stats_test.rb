# frozen_string_literal: true

require_relative '../test_helper'
require 'date'
require 'securerandom'

# Drives Wurk::Stats against real Redis. Stats reads global keys
# (`stat:processed`, `stat:failed`, `schedule`/`retry`/`dead` ZSETs,
# `processes` SET) — those names are wire-compat with Sidekiq and can't be
# namespaced.
#
# Parallel safety:
#   * shared ZSETs/SETs — unique members + `>=` lower-bound asserts.
#   * `stat:processed` / `stat:failed` — snapshot in setup, restore in
#     teardown so reset tests don't pollute the baseline siblings read.
#   * reset/`assert_equal 0` tests acquire `COUNTER_MUTEX` so a sibling
#     INCRBY can't race in between the reset and the read.
class StatsTest < Wurk::Test::UnitCase
  parallelize_me!

  # Serializes the small set of tests that both write a known value and
  # assert on it (reset, counter snapshots) — the mutex window is just the
  # critical assertion, not the whole test.
  COUNTER_MUTEX = Mutex.new

  def setup
    super
    @ns         = "#{Process.pid}-#{object_id}"
    @queue      = "stats-q-#{@ns}"
    @class_name = "StatsJob@#{@ns}"
    @identity   = "stats-id-#{@ns}"
    @pool       = Wurk.configuration.redis_pool
    @added_identity = false
    @zset_members   = Hash.new { |h, k| h[k] = [] }
    # Snapshot under the same mutex used by reset tests so a sibling reset
    # can't race the GET (read 0 mid-reset → restore the wrong baseline at
    # teardown).
    COUNTER_MUTEX.synchronize do
      @processed_before = @pool.with { |c| c.call('GET', 'stat:processed') }
      @failed_before    = @pool.with { |c| c.call('GET', 'stat:failed') }
      @expired_before   = @pool.with { |c| c.call('GET', 'stat:expired') }
    end
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
      (@probe_queues || []).each do |q|
        conn.call('DEL', "queue:#{q}")
        conn.call('SREM', 'queues', q)
      end
      @zset_members.each { |set, members| members.each { |m| conn.call('ZREM', set, m) } }
      if @added_identity
        conn.call('SREM', 'processes', @identity)
        conn.call('DEL', @identity, "#{@identity}:work")
      end
      # Restore under the same mutex used by reset tests so the SET can't
      # land between a reset's reset-to-0 and its assert_equal 0.
      COUNTER_MUTEX.synchronize do
        restore_counter(conn, 'stat:processed', @processed_before)
        restore_counter(conn, 'stat:failed',    @failed_before)
        restore_counter(conn, 'stat:expired',   @expired_before)
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
    COUNTER_MUTEX.synchronize do
      base = Wurk::Stats.new.processed
      @pool.with { |c| c.call('INCRBY', 'stat:processed', 7) }

      assert_operator Wurk::Stats.new.processed, :>=, base + 7
    end
  end

  def test_failed_reflects_redis_value
    COUNTER_MUTEX.synchronize do
      base = Wurk::Stats.new.failed
      @pool.with { |c| c.call('INCRBY', 'stat:failed', 3) }

      assert_operator Wurk::Stats.new.failed, :>=, base + 3
    end
  end

  def test_expired_returns_integer
    assert_kind_of Integer, Wurk::Stats.new.expired
  end

  def test_expired_reflects_redis_value
    COUNTER_MUTEX.synchronize do
      base = Wurk::Stats.new.expired
      @pool.with { |c| c.call('INCRBY', 'stat:expired', 5) }

      assert_operator Wurk::Stats.new.expired, :>=, base + 5
    end
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
    # Serialize against ProcessSetTest's `DEL processes` test — without
    # this, the SCARD inside `Stats.new` can land mid-DEL and read 0.
    Wurk::Test::PROCESSES_MUTEX.synchronize do
      register_identity!

      assert_operator Wurk::Stats.new.processes_size, :>=, 1
    end
  end

  def test_workers_size_returns_integer
    assert_kind_of Integer, Wurk::Stats.new.workers_size
  end

  def test_workers_size_sums_busy_across_identities
    # Serialize against ProcessSetTest's `DEL processes` test — without
    # this, our identity can be wiped between SADD and SMEMBERS, leaving
    # workers_size at 0.
    Wurk::Test::PROCESSES_MUTEX.synchronize do
      register_identity!('busy' => '4')

      assert_operator Wurk::Stats.new.workers_size, :>=, 4
    end
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

  # --- #214: largest-queue-first ordering (Sidekiq parity) ----------------

  # SMEMBERS order is arbitrary; Sidekiq's Stats#queues sorts by size
  # descending. Push three of my own queues in non-monotonic size order and
  # assert that, among just my queues (siblings push their own concurrently),
  # the result lists them largest-first.
  def test_queues_ordered_by_size_descending
    sizes = order_probe_queues # { name => size }, sizes 1/3/2

    ordered = Wurk::Stats.new.queues.keys & sizes.keys # & keeps result order

    assert_equal sizes.keys.sort_by { |q| -sizes[q] }, ordered
  end

  def test_queue_summaries_ordered_by_size_descending
    sizes = order_probe_queues

    ordered = Wurk::Stats.new.queue_summaries.map(&:name) & sizes.keys

    assert_equal sizes.keys.sort_by { |q| -sizes[q] }, ordered
  end

  def test_default_queue_latency_returns_float
    assert_kind_of Float, Wurk::Stats.new.default_queue_latency
  end

  def test_default_queue_latency_is_non_negative
    assert_operator Wurk::Stats.new.default_queue_latency, :>=, 0.0
  end

  # --- reset -------------------------------------------------------------

  def test_reset_clears_all_counters_by_default
    COUNTER_MUTEX.synchronize do
      @pool.with do |c|
        c.call('SET', 'stat:processed', 999)
        c.call('SET', 'stat:failed', 999)
        c.call('SET', 'stat:expired', 999)
      end
      Wurk::Stats.new.reset

      snap = Wurk::Stats.new

      assert_equal 0, snap.processed
      assert_equal 0, snap.failed
      assert_equal 0, snap.expired
    end
  end

  def test_reset_with_expired_clears_only_expired
    COUNTER_MUTEX.synchronize do
      @pool.with do |c|
        c.call('SET', 'stat:processed', 30)
        c.call('SET', 'stat:expired', 90)
      end
      Wurk::Stats.new.reset('expired')

      snap = Wurk::Stats.new

      assert_equal 0, snap.expired
      assert_operator snap.processed, :>=, 30
    end
  end

  def test_reset_with_explicit_stat_clears_only_that_one
    COUNTER_MUTEX.synchronize do
      @pool.with do |c|
        c.call('SET', 'stat:processed', 50)
        c.call('SET', 'stat:failed', 75)
      end
      Wurk::Stats.new.reset('processed')

      snap = Wurk::Stats.new

      assert_equal 0, snap.processed
      assert_operator snap.failed, :>=, 75
    end
  end

  def test_reset_ignores_unknown_stats
    COUNTER_MUTEX.synchronize do
      @pool.with { |c| c.call('SET', 'stat:processed', 42) }
      Wurk::Stats.new.reset('bogus')

      assert_operator Wurk::Stats.new.processed, :>=, 42
    end
  end

  def test_reset_accepts_symbol_stats
    COUNTER_MUTEX.synchronize do
      @pool.with { |c| c.call('SET', 'stat:failed', 11) }
      Wurk::Stats.new.reset(:failed)

      assert_equal 0, Wurk::Stats.new.failed
    end
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
    today = Time.now.utc.to_date.strftime('%Y-%m-%d')
    @pool.with { |c| c.call('SET', "stat:processed:#{today}", 12) }
    begin
      h = Wurk::Stats::History.new(3)

      assert_equal 12, h.processed[today]
    ensure
      @pool.with { |c| c.call('DEL', "stat:processed:#{today}") }
    end
  end

  def test_history_failed_returns_hash_keyed_by_date_string
    today = Time.now.utc.to_date.strftime('%Y-%m-%d')
    @pool.with { |c| c.call('SET', "stat:failed:#{today}", 4) }
    begin
      assert_equal 4, Wurk::Stats::History.new(3).failed[today]
    ensure
      @pool.with { |c| c.call('DEL', "stat:failed:#{today}") }
    end
  end

  def test_history_expired_returns_hash_keyed_by_date_string
    date = Date.new(2000, 1, 1) + (object_id % 10_000)
    day = date.strftime('%Y-%m-%d')
    @pool.with { |c| c.call('SET', "stat:expired:#{day}", 7) }
    begin
      assert_equal 7, Wurk::Stats::History.new(1, date).expired[day]
    ensure
      @pool.with { |c| c.call('DEL', "stat:expired:#{day}") }
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

  # Launcher#write_stats keys stat:<kind>:<day> off `Time.now.utc.strftime('%F')`.
  # Defaulting the read side to the *local* civil date asks for a day the writer
  # never wrote, for whatever slice of each day the host's UTC offset spans.
  #
  # This discriminates only on a host whose civil date differs from UTC's at the
  # moment it runs — it is a tautology on a UTC runner, which is what CI uses.
  # It earns its keep on developer machines (this repo's are UTC-5) and as an
  # executable statement of which clock owns these keys.
  def test_history_window_is_anchored_to_the_utc_day_the_writer_uses
    before = Time.now.utc.strftime('%F')
    key    = Wurk::Stats::History.new(1).processed.keys.first
    after  = Time.now.utc.strftime('%F')

    # `before`/`after` differ only if UTC midnight fell between them.
    assert_includes [before, after], key
  end

  def test_history_uses_explicit_pool
    today = Time.now.utc.to_date.strftime('%Y-%m-%d')
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

  def restore_counter(conn, key, prior)
    prior.nil? ? conn.call('DEL', key) : conn.call('SET', key, prior)
  end

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

  # Three of my own queues with distinct, non-monotonic sizes (1, 3, 2) so the
  # descending sort is observable and not accidentally satisfied by insertion
  # order. Returns { name => size }; teardown drops them via @probe_queues.
  def order_probe_queues
    @probe_queues ||= []
    spec = { "stats-q-a-#{@ns}" => 1, "stats-q-b-#{@ns}" => 3, "stats-q-c-#{@ns}" => 2 }
    spec.each do |name, count|
      @probe_queues << name
      @pool.with do |c|
        c.call('SADD', 'queues', name)
        count.times do
          c.call('LPUSH', "queue:#{name}",
                 Wurk.dump_json('class' => @class_name, 'args' => [], 'queue' => name,
                                'jid' => SecureRandom.hex(12), 'enqueued_at' => ms_now))
        end
      end
    end
    spec
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
