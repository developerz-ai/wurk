# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Branch-coverage tests for Wurk::Client (issue #67). Targets the conditional
# sides not exercised by client_push_test.rb / client_outage_test.rb:
# #middleware block-vs-no-block, #cancel! validation + write, #flush_batched
# empty guard + Lua NOSCRIPT recovery, push_bulk all-halted compaction, and
# the expand_at / expand_spread validation matrix.
#
# Real Redis only (Wurk::Test.redis_url); teardown's worker-DB FLUSHDB gives
# each test a clean slate, so SCRIPT FLUSH / crafted WRONGTYPE keys here can't
# bleed into siblings (classes run sequentially within a worker).
class ClientTest < Wurk::Test::UnitCase
  parallelize_me!

  JID_PATTERN = /\A[0-9a-f]{24}\z/

  def setup
    super
    @queue      = "cb-q-#{Process.pid}-#{object_id}"
    @class_name = "ClientBranchJob@#{Process.pid}-#{object_id}"
    @pool       = Wurk.configuration.redis_pool
    @client     = Wurk::Client.new(pool: @pool)
  end

  # --- #middleware: line 32 then (no block) / else (block) ----------------

  def test_middleware_without_block_returns_same_chain
    chain = Wurk::Client.new.middleware

    assert_instance_of Wurk::Middleware::Chain, chain
  end

  def test_middleware_with_block_yields_and_returns_a_copy
    client   = Wurk::Client.new
    original = client.middleware
    yielded  = nil

    copy = client.middleware { |c| yielded = c }

    refute_same original, copy, 'block form must return a duplicate, not the live chain'
    assert_same copy, yielded, 'the yielded chain must be the returned copy'
  end

  # --- #cancel!: line 69 then (raise) / else (write) ----------------------

  def test_cancel_raises_on_nil_jid
    err = assert_raises(ArgumentError) { @client.cancel!(nil) }

    assert_match(/non-empty String/, err.message)
  end

  def test_cancel_raises_on_empty_jid
    assert_raises(ArgumentError) { @client.cancel!('') }
  end

  def test_cancel_writes_cancelled_flag_with_ttl_and_returns_epoch_seconds
    jid    = 'a' * 24
    before = Process.clock_gettime(Process::CLOCK_REALTIME).to_i

    ts = @client.cancel!(jid)

    assert_operator ts, :>=, before
    flag, ttl = @pool.with do |c|
      [c.call('HGET', "it-#{jid}", 'cancelled'), c.call('TTL', "it-#{jid}")]
    end

    assert_equal ts, flag.to_i
    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, Wurk::IterableJob::CANCELLATION_PERIOD
  ensure
    @pool.with { |c| c.call('DEL', "it-#{jid}") }
  end

  # --- #flush_batched: line 83 then (empty guard) / else (writes) ---------

  def test_flush_batched_empty_is_noop
    assert_nil @client.flush_batched([])
  end

  def test_flush_batched_pushes_batched_payload_through_lua
    @client.flush_batched([batched_payload(jid: 'b1' + ('0' * 22))])

    assert_equal(1, @pool.with { |c| c.call('LLEN', "queue:#{@queue}") })
    assert_equal('1', @pool.with { |c| c.call('HGET', "b-#{@bid}", 'pending') })
  ensure
    cleanup_batch
  end

  # --- push_batched_pipelined NOSCRIPT recovery (else branch) --------------

  def test_flush_batched_reloads_lua_after_script_flush
    @pool.with { |c| c.call('SCRIPT', 'FLUSH') }

    @client.flush_batched([batched_payload(jid: 'b2' + ('0' * 22))])

    assert_equal 1, @pool.with { |c| c.call('LLEN', "queue:#{@queue}") },
                 'NOSCRIPT must trigger script_load_all + EVAL-source retry, then succeed'
  ensure
    cleanup_batch
  end

  # --- push_batched_pipelined re-raise on non-NOSCRIPT (then branch) -------

  def test_flush_batched_reraises_non_noscript_command_error
    # b-<bid> as a String makes the BATCH_PUSH Lua's HINCRBY raise WRONGTYPE
    # (a CommandError that is *not* NOSCRIPT), which must propagate, not retry.
    payload = batched_payload(jid: 'b3' + ('0' * 22)) # sets @bid
    @pool.with { |c| c.call('SET', "b-#{@bid}", 'not-a-hash') }

    assert_raises(RedisClient::CommandError) { @client.flush_batched([payload]) }
  ensure
    cleanup_batch
  end

  # --- push_batched_scheduled_pipelined NOSCRIPT recovery -----------------
  # Scheduled-in-batch jobs (`bid` + `at`) route through BATCH_SCHEDULE; mirror
  # the immediate-path recovery tests so the scheduled path's rescue/re-raise
  # branches stay covered.

  def test_scheduled_batched_push_reloads_lua_after_script_flush
    @bid = "BS-#{Process.pid}-#{object_id}"
    @pool.with { |c| c.call('SCRIPT', 'FLUSH') }

    @client.push(scheduled_batched_item)

    assert_equal('1', @pool.with { |c| c.call('HGET', "b-#{@bid}", 'total') },
                 'NOSCRIPT on BATCH_SCHEDULE must reload + EVAL-source retry, then register')
  ensure
    cleanup_scheduled_batch
  end

  def test_scheduled_batched_push_reraises_non_noscript_command_error
    @bid = "BS2-#{Process.pid}-#{object_id}"
    # b-<bid> as a String makes BATCH_SCHEDULE's HINCRBY raise WRONGTYPE — a
    # CommandError that is not NOSCRIPT, so it must propagate, not retry.
    @pool.with { |c| c.call('SET', "b-#{@bid}", 'not-a-hash') }

    assert_raises(RedisClient::CommandError) { @client.push(scheduled_batched_item) }
  ensure
    cleanup_scheduled_batch
  end

  # --- push_bulk all-halted: line 163 else (compacted empty) --------------

  def test_push_bulk_with_halting_middleware_pushes_nothing
    chain = Wurk::Middleware::Chain.new(Wurk.configuration)
    chain.add(HaltMiddleware)
    client = Wurk::Client.new(pool: @pool, chain: chain)

    result = client.push_bulk('class' => @class_name, 'args' => [[1], [2]], 'queue' => @queue)

    assert_equal [nil, nil], result, 'halted jobs report nil jids'
    assert_equal(0, @pool.with { |c| c.call('LLEN', "queue:#{@queue}") })
  ensure
    @pool.with { |c| c.call('DEL', "queue:#{@queue}") }
  end

  # --- expand_at: line 188 then (non-numeric) / 194 else (bad type) -------

  def test_push_bulk_rejects_non_numeric_at_array_entry
    err = assert_raises(ArgumentError) do
      @client.push_bulk('class' => @class_name, 'args' => [[1], [2]],
                        'queue' => @queue, 'at' => [future_seconds(10), 'soon'])
    end

    assert_match(/only Numeric/, err.message)
  end

  def test_push_bulk_rejects_at_of_unsupported_type
    err = assert_raises(ArgumentError) do
      @client.push_bulk('class' => @class_name, 'args' => [[1]],
                        'queue' => @queue, 'at' => 'whenever')
    end

    assert_match(/'at' must be Numeric or Array/, err.message)
  end

  # --- expand_spread: line 199 then (no key→nil) / else + 202 then/else ---

  def test_push_bulk_without_at_or_spread_enqueues_immediately
    # No `at` and no `spread_interval`: expand_at → expand_spread returns nil,
    # so jobs go straight onto the queue list (not the schedule zset).
    @client.push_bulk('class' => @class_name, 'args' => [[1], [2]], 'queue' => @queue)

    assert_equal(2, @pool.with { |c| c.call('LLEN', "queue:#{@queue}") })
  ensure
    @pool.with { |c| c.call('DEL', "queue:#{@queue}") }
  end

  def test_push_bulk_rejects_non_positive_spread_interval
    err = assert_raises(ArgumentError) do
      @client.push_bulk('class' => @class_name, 'args' => [[1]],
                        'queue' => @queue, 'spread_interval' => -1)
    end

    assert_match(/positive Numeric/, err.message)
  end

  def test_push_bulk_rejects_non_numeric_spread_interval
    assert_raises(ArgumentError) do
      @client.push_bulk('class' => @class_name, 'args' => [[1]],
                        'queue' => @queue, 'spread_interval' => 'fast')
    end
  end

  def test_push_bulk_with_valid_spread_interval_schedules_all_jobs
    @client.push_bulk('class' => @class_name, 'args' => [[1], [2], [3]],
                      'queue' => @queue, 'spread_interval' => 10)

    assert_equal 3, mine_in_schedule.size, 'spread_interval routes every job to the schedule zset'
    assert_equal(0, @pool.with { |c| c.call('LLEN', "queue:#{@queue}") })
  ensure
    cleanup_schedule
  end

  private

  def future_seconds(delta)
    Process.clock_gettime(Process::CLOCK_REALTIME) + delta
  end

  def batched_payload(jid:)
    @bid ||= "B-#{Process.pid}-#{object_id}"
    { 'class' => @class_name, 'args' => [1], 'queue' => @queue, 'jid' => jid, 'bid' => @bid }
  end

  # A `bid` + future `at` payload — the scheduled sibling of batched_payload.
  def scheduled_batched_item
    { 'class' => @class_name, 'args' => [1], 'queue' => @queue, 'bid' => @bid, 'at' => future_seconds(600) }
  end

  def cleanup_batch
    @pool.with do |c|
      c.call('DEL', "queue:#{@queue}", "b-#{@bid}", "b-#{@bid}-jids")
    end
  end

  def cleanup_scheduled_batch
    cleanup_schedule
    @pool.with { |c| c.call('DEL', "b-#{@bid}", "b-#{@bid}-jids") }
  end

  def mine_in_schedule
    @pool.with { |c| c.call('ZRANGE', 'schedule', 0, -1) }.select do |member|
      JSON.parse(member)['class'] == @class_name
    rescue JSON::ParserError
      false
    end
  end

  def cleanup_schedule
    @pool.with do |c|
      mine_in_schedule.each { |member| c.call('ZREM', 'schedule', member) }
    end
  end

  # Client middleware that halts every push (returns falsy from the chain).
  class HaltMiddleware
    def call(_worker, _job, _queue, _redis)
      nil
    end
  end
end
