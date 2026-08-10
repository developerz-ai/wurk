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
    @pool = Wurk.configuration.redis_pool
    # Prime the server-wide EVALSHA cache, exactly as ChildBoot does per fork.
    # Nothing else in the suite guarantees it: the cache only warms as a side
    # effect of some earlier test's inline NOSCRIPT recovery, and with
    # `parallelize_me!` plus a random --seed whether that happened before this
    # file runs is luck. Cold, two things break here — the raw `conn.pipelined`
    # in the per-job-parity test bypasses `eval_batched_slice`, so its NOSCRIPT
    # has no rescue and errors the test; and in the round-trip tests the
    # recovery fires and spends a `script_load_all` plus a replay pipeline,
    # turning `assert_equal 1, @probe.pipelines` into 3. Same one-liner the
    # limiter and lua suites already use in their own setup.
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
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

    assert_pipelines 1, 'four BATCH_PUSH EVALSHAs must ride one pipeline, not four round trips'
    assert_equal 4, llen
  end

  def test_scheduled_batched_push_spends_one_round_trip_for_a_whole_slice
    client = Wurk::Client.new(pool: probe_pool)

    client.send(:raw_push, payloads(4, at: future_seconds(600)))

    assert_pipelines 1, 'four BATCH_SCHEDULE EVALSHAs must ride one pipeline'
    assert_equal 4, scheduled_members.size
  end

  # --- the cap: one pipeline per slice, nothing lost or doubled ------------

  def test_batched_push_opens_a_second_pipeline_past_the_slice_cap
    client = Wurk::Client.new(pool: probe_pool)

    client.flush_batched(payloads(SLICE + 1))

    assert_pipelines 2, 'one pipeline per slice'
    assert_equal SLICE + 1, llen, 'every payload in every slice must land exactly once'
    assert_equal (SLICE + 1).to_s, batch_field('total')
  end

  def test_scheduled_batched_push_opens_a_second_pipeline_past_the_slice_cap
    client = Wurk::Client.new(pool: probe_pool)

    client.send(:raw_push, payloads(SLICE + 1, at: future_seconds(600)))

    assert_pipelines 2, 'one pipeline per slice'
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

  # --- identical Redis state: pipelined vs per-job (Plan 04/S8) -----------
  #
  # The pipeline only changes how many round trips the N EVALSHA calls ride
  # in — the Lua script and its per-job KEYS/ARGV are untouched. Runs the
  # exact same private #push_batched twice against disjoint bid/queue
  # namespaces: once wrapped in `pipelined` (today's path), once against a
  # bare connection so each EVALSHA is its own round trip (the pre-#313
  # per-job path). Diffs the resulting batch hash, live-jid set, and queued
  # payloads — normalized for the namespace names, which differ by design so
  # the two runs don't collide.
  def test_pipelined_batch_push_matches_per_job_redis_state
    now             = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    pipelined_bid   = "#{@bid}-pl"
    per_job_bid     = "#{@bid}-pj"
    pipelined_queue = "#{@queue}-pl"
    per_job_queue   = "#{@queue}-pj"
    client          = Wurk::Client.new(pool: @pool)

    @pool.with do |conn|
      conn.pipelined do |pipe|
        client.send(:push_batched, pipe, payloads(5, bid: pipelined_bid, queue: pipelined_queue), now)
      end
    end
    @pool.with do |conn|
      client.send(:push_batched, conn, payloads(5, bid: per_job_bid, queue: per_job_queue), now)
    end

    assert_equal batch_state(pipelined_bid, pipelined_queue), batch_state(per_job_bid, per_job_queue)
  ensure
    cleanup_namespace(pipelined_bid, pipelined_queue)
    cleanup_namespace(per_job_bid, per_job_queue)
  end

  private

  def payloads(count, at: nil, bid: @bid, queue: @queue)
    Array.new(count) do |i|
      job = { 'class' => @class_name, 'args' => [i], 'queue' => queue,
              'jid' => format('%024x', i), 'bid' => bid }
      at ? job.merge('at' => at) : job
    end
  end

  def batch_state(bid, queue)
    @pool.with do |conn|
      {
        total: conn.call('HGET', "b-#{bid}", 'total'),
        pending: conn.call('HGET', "b-#{bid}", 'pending'),
        jids: conn.call('SMEMBERS', "b-#{bid}-jids").sort,
        jobs: conn.call('LRANGE', "queue:#{queue}", 0, -1).map { |s| JSON.parse(s).except('queue', 'bid') }
      }
    end
  end

  def cleanup_namespace(bid, queue)
    @pool.with do |conn|
      conn.call('DEL', "queue:#{queue}", "b-#{bid}", "b-#{bid}-jids")
      conn.call('SREM', 'queues', queue)
    end
  end

  def future_seconds(delta)
    Process.clock_gettime(Process::CLOCK_REALTIME) + delta
  end

  # Pipeline counts are only meaningful if nothing reloaded the script cache
  # mid-measurement. See ProbeConn#foreign_noscript? — a sibling worker's
  # `SCRIPT FLUSH` costs the client a reload and a replay, which is the right
  # behaviour and the wrong number, and there is no way to hold a server-wide
  # cache still from in here.
  def assert_pipelines(expected, message)
    skip 'a sibling suite flushed the server-wide script cache mid-measurement' if @probe.foreign_noscript?

    assert_equal expected, @probe.pipelines, message
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
      @foreign_noscript = false
    end

    # True when REAL Redis answered a pipeline with NOSCRIPT — i.e. a sibling
    # worker ran `SCRIPT FLUSH` (four suites still do, and the cache is
    # server-wide) between this test's setup priming and its measured call. The
    # client then recovers by reloading and replaying, which is correct
    # behaviour and two extra pipelines, so the count this class exists to
    # measure is simply not measurable on that run. Staged NOSCRIPTs raised by
    # `noscript_on` below are ours and deliberately do not set it.
    def foreign_noscript? = @foreign_noscript

    def pipelined(&)
      @pipelines += 1
      raise RedisClient::ConnectionError, 'simulated mid-push drop' if @drop_after && @pipelines > @drop_after

      if @noscript_on == @pipelines
        @noscript_on = nil
        raise RedisClient::CommandError, 'NOSCRIPT No matching script. Use EVAL.'
      end

      begin
        @real.pipelined(&)
      rescue RedisClient::CommandError => e
        @foreign_noscript = true if e.message.start_with?('NOSCRIPT')
        raise
      end
    end

    def call(*, &) = @real.call(*, &)

    def close = @real.close
  end
end
