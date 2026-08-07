# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'stringio'

# Drives Wurk::Client against real Redis. Asserts on the canonical Sidekiq
# wire shape — keys, JID format, ms timestamps — and on the validation
# surface (symbol keys, missing fields, bulk shape).
#
# Parallel safety: every test routes through a queue name derived from
# `@wurk_test_namespace`, so no two tests share a Redis list. Scheduled
# pushes use a unique class name (`ClientPushJob@<namespace>`) so we can
# clean them out of the global `schedule` zset in teardown.
class ClientPushTest < Wurk::Test::UnitCase
  parallelize_me!

  JID_PATTERN = /\A[0-9a-f]{24}\z/
  EPOCH_FLOOR = 1_700_000_000_000 # well past Jan-2024 in ms; catches second-vs-ms bugs
  NOOP = proc {}

  def setup
    super
    @queue      = "q-#{Process.pid}-#{object_id}"
    @class_name = "ClientPushJob@#{Process.pid}-#{object_id}"
    @client     = Wurk::Client.new
    @pool       = Wurk.configuration.redis_pool
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue) if @queue
      cleanup_schedule(conn)
    end
  ensure
    super
  end

  # --- push: shape & wire-compat -----------------------------------------

  def test_push_returns_24_hex_jid
    assert_match JID_PATTERN, @client.push(base_item)
  end

  # rubocop:disable Minitest/MultipleAssertions
  # One test, one canonical shape — splitting it 5 ways would obscure
  # the contract ("the LPUSH'd JSON has exactly these fields").
  def test_push_writes_lpush_with_canonical_json_keys
    @client.push(base_item('args' => [1, 'two']))
    payload = first_queued

    assert_equal @class_name, payload['class']
    assert_equal [1, 'two'],  payload['args']
    assert_equal @queue,      payload['queue']
    assert_match JID_PATTERN, payload['jid']
    assert payload['retry'], 'retry defaults to true (Wurk.default_job_options)'
  end
  # rubocop:enable Minitest/MultipleAssertions

  # `pool` is a transient enqueue-time attribute (spec §2.2) — it selects the
  # Redis pool but must never reach the wire. Issue #95.
  def test_push_strips_transient_pool_from_payload
    @client.push(base_item('pool' => 'some-pool'))

    refute first_queued.key?('pool'), 'pool must be stripped before push'
  end

  def test_push_stamps_ms_created_at_in_range
    before = ms_now
    @client.push(base_item)
    after = ms_now

    assert_ms_in_range first_queued['created_at'], before, after
  end

  def test_push_stamps_ms_enqueued_at_in_range
    before = ms_now
    @client.push(base_item)
    after = ms_now

    assert_ms_in_range first_queued['enqueued_at'], before, after
  end

  def test_push_adds_queue_to_queues_set
    @client.push(base_item)

    assert_includes @pool.with { |c| c.call('SMEMBERS', 'queues') }, @queue
  end

  def test_push_is_lpush_so_oldest_lands_at_tail
    @client.push(base_item('args' => [1]))
    @client.push(base_item('args' => [2]))

    assert_equal [[2], [1]], queued_args
  end

  # --- push: scheduled ---------------------------------------------------

  def test_scheduled_push_zadds_with_correct_score
    at = future_seconds(600)
    @client.push(base_item('at' => at))
    payload, score = mine_in_schedule.first

    refute_nil payload, 'expected scheduled job in `schedule` zset'
    assert_in_delta at, score.to_f, 0.01
  end

  def test_scheduled_payload_strips_at_and_enqueued_at
    @client.push(base_item('at' => future_seconds(600)))
    payload, = mine_in_schedule.first

    refute payload.key?('at'),          '`at` must be stripped from scheduled payload'
    refute payload.key?('enqueued_at'), '`enqueued_at` must not exist on scheduled payload'
    assert_match JID_PATTERN, payload['jid']
  end

  def test_scheduled_push_does_not_add_to_queues_set
    @client.push(base_item('at' => future_seconds(600)))

    refute_includes @pool.with { |c| c.call('SMEMBERS', 'queues') }, @queue
  end

  # --- validation surface ------------------------------------------------

  def test_push_raises_on_symbol_top_level_keys
    err = assert_raises(ArgumentError) do
      @client.push(class: @class_name, args: [], queue: @queue)
    end

    assert_match(/Hash with 'class' and 'args'/, err.message)
  end

  def test_push_raises_when_args_not_array
    err = assert_raises(ArgumentError) do
      @client.push(base_item('args' => { 'k' => 'v' }))
    end

    assert_match(/args must be an Array/, err.message)
  end

  def test_push_raises_when_class_missing
    err = assert_raises(ArgumentError) do
      @client.push('args' => [])
    end

    assert_match(/Hash with 'class' and 'args'/, err.message)
  end

  def test_push_raises_when_queue_blank
    err = assert_raises(ArgumentError) do
      @client.push(base_item('queue' => ''))
    end

    assert_match(/non-empty queue/, err.message)
  end

  # --- push_bulk ---------------------------------------------------------

  def test_push_bulk_returns_array_of_unique_24hex_jids
    result = @client.push_bulk(base_item('args' => [[1], [2], [3]]))

    assert_equal 3, result.size
    result.each { |jid| assert_match JID_PATTERN, jid }
    assert_equal result.uniq.size, result.size
  end

  def test_push_bulk_lpushes_each_job
    @client.push_bulk(base_item('args' => [[1], [2]]))

    assert_equal [[1], [2]].sort, queued_args.sort
  end

  def test_push_bulk_assigns_distinct_jids_per_job
    @client.push_bulk(base_item('args' => [[1], [2]]))

    assert_equal 2, queued_payloads.map { |p| p['jid'] }.uniq.size
  end

  def test_push_bulk_returns_empty_for_empty_args
    assert_empty @client.push_bulk(base_item('args' => []))
  end

  def test_push_bulk_rejects_non_array_args
    err = assert_raises(ArgumentError) do
      @client.push_bulk(base_item('args' => [1, 2]))
    end

    assert_match(/Array of Arrays/, err.message)
  end

  def test_push_bulk_rejects_explicit_jid_for_multi_job
    err = assert_raises(ArgumentError) do
      @client.push_bulk(base_item('args' => [[1], [2]], 'jid' => 'aaa'))
    end

    assert_match(/single-job/, err.message)
  end

  def test_push_bulk_rejects_at_and_spread_interval_together
    err = assert_raises(ArgumentError) do
      @client.push_bulk(base_item('args' => [[1]], 'at' => future_seconds(0), 'spread_interval' => 10))
    end

    assert_match(/'at' and 'spread_interval'/, err.message)
  end

  def test_push_bulk_with_scalar_at_schedules_all_at_same_time
    at = future_seconds(900)
    @client.push_bulk(base_item('args' => [[1], [2]], 'at' => at))
    pairs = mine_in_schedule

    assert_equal 2, pairs.size
    pairs.map(&:last).each { |score| assert_in_delta at, score.to_f, 0.01 }
  end

  def test_push_bulk_with_array_at_schedules_per_job
    a1 = future_seconds(100)
    a2 = future_seconds(200)
    @client.push_bulk(base_item('args' => [[1], [2]], 'at' => [a1, a2]))

    assert_equal [a1, a2].sort, mine_in_schedule.map { |_p, s| s.to_f }.sort
  end

  def test_push_bulk_rejects_mismatched_at_array_size
    assert_raises(ArgumentError) do
      @client.push_bulk(base_item('args' => [[1], [2]], 'at' => [future_seconds(0)]))
    end
  end

  # --- verify_json: exactly once per push (Plan 04/S8) --------------------
  #
  # #push used to walk the payload's args twice (once inside the client
  # middleware chain, once again on the returned payload); #push_bulk still
  # walks once per job, inside the chain. A spy on the public `verify_json`
  # method counts real invocations against real Redis, so a regression that
  # reintroduces the second walk — or drops the only one — trips a count
  # mismatch instead of just costing allocations silently.
  def test_push_calls_verify_json_exactly_once
    calls = 0
    @client.define_singleton_method(:verify_json) do |item|
      calls += 1
      super(item)
    end

    @client.push(base_item)

    assert_equal 1, calls
  end

  def test_push_bulk_calls_verify_json_exactly_once_per_job
    calls = 0
    @client.define_singleton_method(:verify_json) do |item|
      calls += 1
      super(item)
    end

    @client.push_bulk(base_item('args' => [[1], [2], [3]]))

    assert_equal 3, calls
  end

  # --- verify_json: :warn/:raise mode matrix -------------------------------
  #
  # Both entry points route unsafe args through the same JobUtil#verify_json,
  # so :raise must raise identically from push and push_bulk, and :warn must
  # let both through unraised (job still lands on the wire) while logging the
  # same message shape. Pins the matrix so a future divergence between the
  # two push paths — e.g. push_bulk regaining its own verify call with a
  # different mode read — shows up as a failing cell, not a shrug.
  def test_push_raises_on_unsafe_args_in_raise_mode
    with_strict_mode(:raise) do
      err = assert_raises(ArgumentError) { @client.push(base_item('args' => [:sym])) }
      assert_match(/native JSON/, err.message)
    end
  end

  def test_push_bulk_raises_on_unsafe_args_in_raise_mode
    with_strict_mode(:raise) do
      err = assert_raises(ArgumentError) { @client.push_bulk(base_item('args' => [[:sym]])) }
      assert_match(/native JSON/, err.message)
    end
  end

  def test_push_warns_without_raising_on_unsafe_args_in_warn_mode
    with_strict_mode(:warn) do
      log = capture_log { @client.push(base_item('args' => [:sym])) }

      assert_match(/native JSON/, log)
      assert_equal [['sym']], queued_args
    end
  end

  def test_push_bulk_warns_without_raising_on_unsafe_args_in_warn_mode
    with_strict_mode(:warn) do
      log = capture_log { @client.push_bulk(base_item('args' => [[:sym]])) }

      assert_match(/native JSON/, log)
      assert_equal [['sym']], queued_args
    end
  end

  # --- pool routing ------------------------------------------------------

  def test_class_via_overrides_pool_in_block
    captured = nil
    other = fake_pool { captured = :other }

    Wurk::Client.via(other) do
      Wurk::Client.new.push(base_item)
    end

    assert_equal :other, captured
  end

  def test_class_via_resets_after_block_even_on_raise
    assert_raises(RuntimeError) do
      Wurk::Client.via(Object.new) { raise 'boom' }
    end
    assert_nil Thread.current[:wurk_via_pool]
  end

  def test_class_via_rejects_reentrant_call
    Wurk::Client.via(Object.new) do
      assert_raises(RuntimeError) { Wurk::Client.via(Object.new, &NOOP) }
    end
  end

  def test_class_via_rejects_nil_pool
    assert_raises(ArgumentError) { Wurk::Client.via(nil, &NOOP) }
  end

  # --- enqueue helpers ---------------------------------------------------

  def test_class_push_delegates_to_instance
    assert_match JID_PATTERN, Wurk::Client.push(base_item)
  end

  def test_class_push_bulk_delegates_to_instance
    assert_equal 2, Wurk::Client.push_bulk(base_item('args' => [[1], [2]])).size
  end

  private

  def base_item(overrides = {})
    { 'class' => @class_name, 'args' => [], 'queue' => @queue }.merge(overrides)
  end

  def ms_now
    Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
  end

  def future_seconds(delta)
    (ms_now / 1000.0) + delta
  end

  def queued_payloads
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |s| JSON.parse(s) }
  end

  def queued_args
    queued_payloads.map { |p| p['args'] }
  end

  def first_queued
    queued_payloads.first
  end

  def assert_ms_in_range(value, lower, upper)
    assert_operator value, :>=, EPOCH_FLOOR, "expected ms-since-epoch, got #{value}"
    assert_operator value, :>=, lower
    assert_operator value, :<=, upper
  end

  # redis-client returns ZRANGE WITHSCORES as [[member, score], ...].
  # We parse each member and keep only the ones targeting this test's class.
  # Sibling parallel tests (e.g. StatsTest) write non-JSON probe members
  # to the shared `schedule` zset; skip those rather than blow up.
  def mine_in_schedule
    @pool.with { |c| c.call('ZRANGE', 'schedule', 0, -1, 'WITHSCORES') }.filter_map do |member, score|
      payload = JSON.parse(member)
      [payload, score] if payload['class'] == @class_name
    rescue JSON::ParserError
      next
    end
  end

  def cleanup_schedule(conn)
    conn.call('ZRANGE', 'schedule', 0, -1).each do |member|
      payload = JSON.parse(member)
      conn.call('ZREM', 'schedule', member) if payload['class'] == @class_name
    rescue JSON::ParserError
      next
    end
  end

  def with_strict_mode(mode)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      original = Wurk.strict_args_mode
      Wurk.strict_args!(mode)
      yield
    ensure
      Wurk.strict_args!(original)
    end
  end

  def capture_log
    io = StringIO.new
    saved = Wurk.configuration.logger
    Wurk.configuration.logger = ::Logger.new(io)
    yield
    io.string
  ensure
    Wurk.configuration.logger = saved
  end

  def fake_pool(&hook)
    pool = Object.new
    pool.define_singleton_method(:with) do |&blk|
      hook&.call
      blk.call(FakeConn.new)
    end
    pool
  end

  # Fake connection for `via` tests. `pipelined` yields self so atomic_push
  # can call `.call(*)` against this same object — no real Redis touched.
  class FakeConn
    def pipelined
      yield self
    end

    def call(*); end
  end
end
