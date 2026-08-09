# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Slice 11, step 6 — the kill switch.
#
# There is no reaper for a stuck flow: that would be a second source of truth
# about whether a flow is alive, needing a leader elected to run it in exactly
# one process, when retention already collects an abandoned graph for free.
# What there is instead is an operator saying so, and this is what that has to
# do — release the weight (a batch's ~9 keys, per node), leave a record of
# where the flow went, and stay safe against the jobs still queued against it.
class FlowAbandonTest < Wurk::Test::UnitCase
  parallelize_me!

  class FetchJob
    include Wurk::Job

    def perform(*); end
  end

  class MergeJob
    include Wurk::Job

    def perform(*); end
  end

  def setup
    super
    @pool     = Wurk.configuration.redis_pool
    @queue    = "flowabandon-#{Process.pid}-#{object_id}"
    @callback = "#{@queue}-cb"
  end

  # --- what it releases ----------------------------------------------------

  def test_abandoning_drops_every_node_record_and_node_batch
    flow = diamond.run

    assert flow.abandon

    assert_equal([0, 0, 0], (0..2).map { |i| exists(Wurk::Keys.flow_node(flow.fid, i)) })
    assert_equal([0, 0, 0], flow.bids.map { |bid| exists("b-#{bid}") })
  end

  # A batch is not one key. The suffix list lives in Ruby and travels into the
  # script, so a batch growing a new subkey cannot leave a flow leaking it.
  def test_abandoning_drops_a_node_batchs_subkeys_too
    flow = diamond.run
    subkeys = Wurk::Batch::KEY_SUFFIXES.map { |suffix| "b-#{flow.bids[0]}-#{suffix}" }

    refute_equal 0, exists("b-#{flow.bids[0]}-jids")
    flow.abandon

    assert_equal(0, subkeys.sum { |key| exists(key) })
  end

  def test_abandoning_takes_the_node_batches_out_of_both_batch_indexes
    flow = diamond.run
    @pool.with { |conn| conn.call('ZADD', 'dead-batches', 1, flow.bids[0]) }

    flow.abandon

    assert_equal(0, flow.bids.count { |bid| zscore('batches', bid) })
    assert_nil zscore('dead-batches', flow.bids[0])
  end

  def test_abandoning_drops_the_dead_node_set
    flow = diamond.run
    kill_node(flow, 0)

    assert_equal 1, exists(Wurk::Keys.flow_dead(flow.fid))
    flow.abandon

    assert_equal 0, exists(Wurk::Keys.flow_dead(flow.fid))
  end

  # --- what it leaves ------------------------------------------------------

  # A flow that vanishes is indistinguishable from one that was never created.
  # The record is also what keeps the release safe, so it is not an optional
  # courtesy — see the claim tests below.
  def test_the_flow_record_survives_marked_abandoned
    flow = diamond.run

    flow.abandon
    record = flow_record(flow)

    assert_equal 'abandoned', record['state']
    assert_in_delta Process.clock_gettime(Process::CLOCK_REALTIME), record['abandoned_at'].to_f, 5
    assert_equal %w[3 3], record.values_at('total', 'pending')
    assert_in_delta Wurk::Batch::DEFAULT_EXPIRY_SECONDS, ttl(Wurk::Keys.flow(flow.fid)), 60
  end

  # When the flow broke is still true, and still the more useful of the two
  # timestamps to whoever is asking why anyone gave up on it.
  def test_abandoning_a_failed_flow_keeps_the_timestamp_it_failed_at
    flow = diamond.run
    kill_node(flow, 0)
    failed_at = flow_record(flow)['failed_at']

    flow.abandon
    record = flow_record(flow)

    assert_equal 'abandoned', record['state']
    assert_equal failed_at, record['failed_at']
    refute_nil record['abandoned_at']
  end

  # It does not chase in-flight jobs out of their queues — same caveat, and the
  # same wording, as Batch::Status#delete.
  def test_abandoning_leaves_jobs_already_on_a_queue_where_they_are
    flow = diamond.run

    flow.abandon

    assert_equal 2, queued.size
  end

  # --- the claim -----------------------------------------------------------

  def test_only_the_call_that_abandons_says_it_did
    flow = diamond.run

    assert flow.abandon
    refute flow.abandon
  end

  def test_a_succeeded_flow_is_not_stuck_and_is_left_alone
    flow = chain.run
    [0, 1].each { |index| succeed(flow, index) }

    refute flow.abandon
    assert_equal 'succeeded', flow_record(flow)['state']
    assert_equal 1, exists(Wurk::Keys.flow_node(flow.fid, 0))
  end

  def test_a_failed_flow_can_still_be_abandoned
    flow = diamond.run
    kill_node(flow, 0)

    assert flow.abandon
    assert_equal 'abandoned', flow_record(flow)['state']
  end

  def test_a_flow_that_was_never_there_is_not_abandoned
    refute Wurk::Flow.abandon('nosuchflow')
  end

  # --- what the jobs still out there can do to it ---------------------------

  # Every write in Flow::Completion claims on a node record this released, so a
  # job that runs and acks against an abandoned flow finds nothing to advance
  # and — this is the part that matters — rebuilds nothing while failing to.
  def test_a_completion_arriving_after_abandonment_writes_nothing
    flow = diamond.run
    flow.abandon

    succeed(flow, 0)
    kill_node(flow, 1)

    assert_equal 'abandoned', flow_record(flow)['state']
    assert_equal '3', flow_record(flow)['pending']
    assert_equal 0, exists(Wurk::Keys.flow_node(flow.fid, 0))
    assert_equal 0, exists(Wurk::Keys.flow_dead(flow.fid))
    assert_equal 2, queued.size
  end

  def test_an_abandoned_flow_never_settles_as_succeeded
    flow = chain.run
    flow.abandon

    [0, 1].each { |index| succeed(flow, index) }

    assert_equal 'abandoned', flow_record(flow)['state']
  end

  def test_the_class_level_kill_switch_takes_a_bare_fid
    flow = diamond.run

    assert Wurk::Flow.abandon(flow.fid)
    assert_equal 'abandoned', flow_record(flow)['state']
  end

  private

  def diamond
    build do |f|
      a = f.job(FetchJob, 'a', name: :a, queue: @queue)
      b = f.job(FetchJob, 'b', name: :b, queue: @queue)
      f.job(MergeJob, depends_on: [a, b], queue: @queue)
    end
  end

  def chain
    build do |f|
      a = f.job(FetchJob, name: :a, queue: @queue)
      f.job(MergeJob, depends_on: a, queue: @queue)
    end
  end

  def build(&)
    flow = Wurk::Flow.new(&)
    flow.callback_queue = @callback
    flow
  end

  def succeed(flow, index)
    Wurk::Flow::Completion.new.on_success(nil, { 'fid' => flow.fid, 'node' => index })
  end

  def kill_node(flow, index)
    Wurk::Flow::Completion.new.on_death(nil, { 'fid' => flow.fid, 'node' => index })
  end

  def exists(key) = @pool.with { |conn| conn.call('EXISTS', key) }
  def zscore(key, member) = @pool.with { |conn| conn.call('ZSCORE', key, member) }
  def flow_record(flow) = hgetall(Wurk::Keys.flow(flow.fid))
  def ttl(key) = @pool.with { |conn| conn.call('TTL', key) }

  def hgetall(key)
    raw = @pool.with { |conn| conn.call('HGETALL', key) }
    raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
  end

  def queued
    @pool.with { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |raw| JSON.parse(raw) }
  end
end
