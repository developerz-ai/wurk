# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# E17 — sibling child batches draining at the same instant as the parent's own
# last job must fire the parent's callbacks exactly once. The old gate made two
# round trips per child (SREM pkids, then SCARD pkids), so two children could
# both read an empty set and both fire the parent; the dedup markers do not
# close that window, since they are written only after the enqueue. Real
# Redis, one connection per thread, every ack released from a shared barrier.
class BatchFireGateStressTest < Wurk::Test::UnitCase
  parallelize_me!

  ROUNDS = 25
  CHILDREN = 6

  def setup
    super
    @pool  = Wurk.configuration.redis_pool
    @queue = "bgs-#{Process.pid}-#{object_id}"
    @cbq   = "bgscb-#{Process.pid}-#{object_id}"
    @bids  = []
  end

  def teardown
    @pool.with do |conn|
      @bids.each do |bid|
        conn.call('UNLINK', *Wurk::Batch.keys_for(bid))
        conn.call('ZREM', 'batches', bid)
      end
      [@queue, @cbq].each do |q|
        conn.call('DEL', "queue:#{q}")
        conn.call('SREM', 'queues', q)
      end
    end
  ensure
    super
  end

  def test_concurrent_drains_fire_the_parent_exactly_once
    ROUNDS.times do |round|
      parent, acks = build_round

      race(acks)

      assert_equal 1, fired(parent.bid, 'complete'), "round #{round}: parent :complete fired more than once"
      assert_equal 1, fired(parent.bid, 'success'), "round #{round}: parent :success fired more than once"
    end
  end

  private

  # A parent with one job of its own and CHILDREN child batches of one job
  # each; returns every [bid, jid] that has to ack for the parent to drain.
  def build_round
    parent = track(Wurk::Batch.new)
    parent.callback_queue = @cbq
    parent.on(:complete, 'StressComplete')
    parent.on(:success, 'StressSuccess')
    children = []
    parent.jobs do
      push
      CHILDREN.times do
        child = track(Wurk::Batch.new)
        child.jobs { push }
        children << child
      end
    end
    [parent, [parent, *children].map { |b| [b.bid, jid_for(b.bid)] }]
  end

  def race(acks)
    gate = Queue.new
    threads = acks.map do |bid, jid|
      Thread.new do
        gate.pop
        mw = Wurk::Batch::ServerMiddleware.new
        mw.config = Wurk.configuration
        mw.call(nil, { 'bid' => bid, 'jid' => jid }, @queue) {}
      end
    end
    acks.size.times { gate << true }
    threads.each(&:join)
  end

  def push
    Wurk::Client.push('class' => 'StressJob', 'args' => [], 'queue' => @queue)
  end

  def track(batch)
    @bids << batch.bid
    batch
  end

  def jid_for(bid)
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }
         .map { |s| JSON.parse(s) }.find { |j| j['bid'] == bid }.fetch('jid')
  end

  def fired(bid, event)
    @pool.with { |c| c.call('LRANGE', "queue:#{@cbq}", 0, -1) }
         .map { |s| JSON.parse(s) }
         .count { |j| j['args'][0] == bid && j['args'][2] == event }
  end
end
