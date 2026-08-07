# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Plan 04/S6. Batched (`bid`) enqueue rides one pipeline, not one round trip
# per job, and that pipeline is capped at Client::BATCH_PIPELINE_SLICE payloads
# so an `autoflush = true` Batch#jobs block can't hand #flush_batched an
# unbounded command set.
#
# Round trips are counted by wrapping the connection and tallying `pipelined`
# calls: every command these paths emit is buffered into a pipeline, so
# pipelines opened == round trips spent. Real Redis throughout — the EVAL-source
# NOSCRIPT retry has to genuinely apply, or "no duplicates" would pass
# vacuously.
class ClientBatchPipelineTest < Wurk::Test::UnitCase
  parallelize_me!

  SLICE = Wurk::Client::BATCH_PIPELINE_SLICE

  def setup
    super
    @pool       = Wurk.configuration.redis_pool
    @queue      = "bp-q-#{Process.pid}-#{object_id}"
    @class_name = "BatchPipelineJob@#{Process.pid}-#{object_id}"
    @bid        = "BP-#{Process.pid}-#{object_id}"
  end

  def teardown
    @probe&.close
    @pool.with do |c|
      c.call('DEL', "queue:#{@queue}", "b-#{@bid}", "b-#{@bid}-jids")
      c.call('SREM', 'queues', @queue)
      mine = mine_in_schedule(c)
      c.call('ZREM', 'schedule', *mine) unless mine.empty?
    end
  ensure
    Thread.current[Wurk::Client::DELIVERED_KEY] = nil
    super
  end

  # --- round trips: N jobs, one pipeline -----------------------------------

  def test_batched_push_spends_one_round_trip_for_a_whole_slice
    client = Wurk::Client.new(pool: probe_pool)

    client.flush_batched(payloads(4))

    assert_equal 1, @probe.pipelines, 'four BATCH_PUSH EVALSHAs must ride one pipeline, not four round trips'
    assert_equal 4, llen
  end

  def test_scheduled_batched_push_spends_one_round_trip_for_a_whole_slice
    client = Wurk::Client.new(pool: probe_pool)

    client.send(:raw_push, payloads(4, at: future_seconds(600)))

    assert_equal 1, @probe.pipelines, 'four BATCH_SCHEDULE EVALSHAs must ride one pipeline'
    assert_equal 4, scheduled_members.size
  end

  # --- the cap: one pipeline per slice, nothing lost or doubled ------------

  def test_batched_push_opens_a_second_pipeline_past_the_slice_cap
    client = Wurk::Client.new(pool: probe_pool)

    client.flush_batched(payloads(SLICE + 1))

    assert_equal 2, @probe.pipelines
    assert_equal SLICE + 1, llen, 'every payload in every slice must land exactly once'
    assert_equal (SLICE + 1).to_s, batch_field('total')
  end

  def test_scheduled_batched_push_opens_a_second_pipeline_past_the_slice_cap
    client = Wurk::Client.new(pool: probe_pool)

    client.send(:raw_push, payloads(SLICE + 1, at: future_seconds(600)))

    assert_equal 2, @probe.pipelines
    assert_equal SLICE + 1, scheduled_members.size
  end

  # `enqueued_at` is stamped once per push (push_immediate computes `now`
  # before the split), so slicing must not restamp the later slices — the
  # whole push has to share one arrival timestamp, as it did unsliced.
  def test_every_slice_shares_the_pushs_single_enqueued_at_stamp
    Wurk::Client.new(pool: probe_pool).flush_batched(payloads(SLICE + 1))

    stamps = queued.map { |j| j['enqueued_at'] }.uniq

    assert_equal 1, stamps.size
  end

  # --- delivery ledger ------------------------------------------------------

  # A slice Redis acknowledged must be in the ledger before the next one goes
  # out; otherwise Client::Buffered reports an already-written batched payload
  # as undelivered when a later slice loses the socket.
  def test_an_acknowledged_slice_is_marked_delivered_before_the_next_one_goes_out
    client = Wurk::Client.new(pool: probe_pool(drop_after: 1))
    jobs   = payloads(SLICE + 1)
    Thread.current[Wurk::Client::DELIVERED_KEY] = []

    assert_raises(RedisClient::ConnectionError) { client.flush_batched(jobs) }

    # By identity, not by value: the ledger's whole point is that Buffered can
    # subtract the very Hash objects this push handed to Redis.
    assert_equal jobs.first(SLICE).map(&:object_id),
                 Thread.current[Wurk::Client::DELIVERED_KEY].map(&:object_id),
                 'exactly the acknowledged slice, and nothing from the one that never got a reply'
  end

  def test_nothing_is_marked_delivered_when_the_first_slice_never_lands
    client = Wurk::Client.new(pool: probe_pool(drop_after: 0))
    Thread.current[Wurk::Client::DELIVERED_KEY] = []

    assert_raises(RedisClient::ConnectionError) { client.flush_batched(payloads(2)) }

    assert_empty Thread.current[Wurk::Client::DELIVERED_KEY]
  end

  # --- NOSCRIPT recovery is per slice --------------------------------------

  # A flushed script cache NOSCRIPTs every EVALSHA in the pipeline and applies
  # none, so replaying that slice through source-embedded EVAL is safe — but
  # only that slice. Replaying the whole push would double the slice that
  # already landed.
  def test_noscript_replays_only_the_failing_slice
    client = Wurk::Client.new(pool: probe_pool(noscript_on: 2))

    client.flush_batched(payloads(SLICE + 1))

    assert_equal SLICE + 1, llen, 'the acknowledged slice must not be re-sent by the reload retry'
    assert_equal (SLICE + 1).to_s, batch_field('total')
  end

  private

  def payloads(count, at: nil)
    Array.new(count) do |i|
      job = { 'class' => @class_name, 'args' => [i], 'queue' => @queue,
              'jid' => format('%024x', i), 'bid' => @bid }
      at ? job.merge('at' => at) : job
    end
  end

  def future_seconds(delta)
    Process.clock_gettime(Process::CLOCK_REALTIME) + delta
  end

  def probe_pool(drop_after: nil, noscript_on: nil)
    @probe = ProbeConn.new(Wurk::Test.redis_url, drop_after: drop_after, noscript_on: noscript_on)
    pool   = Object.new
    probe  = @probe
    pool.define_singleton_method(:with) { |&blk| blk.call(probe) }
    pool
  end

  def llen
    @pool.with { |c| c.call('LLEN', "queue:#{@queue}") }
  end

  def queued
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |s| JSON.parse(s) }
  end

  def batch_field(field)
    @pool.with { |c| c.call('HGET', "b-#{@bid}", field) }
  end

  def scheduled_members
    @pool.with { |c| mine_in_schedule(c) }
  end

  def mine_in_schedule(conn)
    conn.call('ZRANGE', 'schedule', 0, -1).select do |member|
      JSON.parse(member)['class'] == @class_name
    rescue JSON::ParserError
      false
    end
  end

  # One real connection that counts the pipelines opened on it and can fault a
  # chosen one. `drop_after` lands that many pipelines and then behaves like a
  # dead socket; `noscript_on` fails the Nth pipeline the way a flushed script
  # cache does — at finalize, never to eval_cached's inline rescue — so the
  # client's reload-and-replay branch runs against real Redis.
  #
  # A real SCRIPT FLUSH is not an option: the EVALSHA cache is server-wide and
  # shared across the parallel_fork workers' isolated DBs.
  class ProbeConn
    attr_reader :pipelines

    def initialize(url, drop_after: nil, noscript_on: nil)
      @real        = RedisClient.config(url: url).new_client
      @drop_after  = drop_after
      @noscript_on = noscript_on
      @pipelines   = 0
    end

    def pipelined(&)
      @pipelines += 1
      raise RedisClient::ConnectionError, 'simulated mid-push drop' if @drop_after && @pipelines > @drop_after

      if @noscript_on == @pipelines
        @noscript_on = nil
        raise RedisClient::CommandError, 'NOSCRIPT No matching script. Use EVAL.'
      end

      @real.pipelined(&)
    end

    def call(*, &) = @real.call(*, &)

    def close = @real.close
  end
end
