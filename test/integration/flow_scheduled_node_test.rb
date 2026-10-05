# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

class FlowScheduledNodeJob
  include Wurk::Job

  def perform(*); end
end

# A flow node declared with `at:` is deferred the way Client#push defers any
# job carrying `at` — onto `schedule`, scored by that epoch, as the bytes
# JobUtil.scheduled_member writes — whether it is a root (released by
# flow_create.lua) or a dependent (released by flow_advance.lua). It used to be
# LPUSHed straight onto its queue, `at` ignored. Real Redis, real scheduler
# promotion, real batch accounting.
#
# Not parallelize_me!: promotion drains the DB's shared `schedule` ZSET.
class FlowScheduledNodeTest < Wurk::Test::UnitCase
  def setup
    super
    @pool  = Wurk.configuration.redis_pool
    @queue = "flowsched-#{Process.pid}-#{object_id}"
    @at    = ::Time.now.to_f + 3600
  end

  def teardown
    @pool.with do |c|
      c.call('DEL', "queue:#{@queue}")
      c.call('SREM', 'queues', @queue)
      @flow&.jids&.each { |jid| c.call('ZREM', 'schedule', member_for(jid)) if member_for(jid) }
    end
  ensure
    super
  end

  def test_a_root_declared_with_at_is_scheduled_not_queued
    @flow = Wurk::Flow.new { |f| f.job(FlowScheduledNodeJob, 1, queue: @queue, at: @at) }.run
    jid = @flow.jids[0]

    assert_empty queued, 'a deferred root must not reach its queue at creation'
    member = member_for(jid)

    refute_nil member, 'the root lands on schedule'
    assert_in_delta @at, score_of(member), 0.001
    refute JSON.parse(member).key?('at'), 'at is the score, not a field'
    refute JSON.parse(member).key?('enqueued_at'), 'the promoter stamps enqueued_at'
    assert_equal %w[1 1], batch(@flow.bids[0]).values_at('total', 'pending'), 'the job is in its batch from the start'
    assert_equal [jid], live_jids(@flow.bids[0])
  end

  def test_a_scheduled_root_is_promoted_onto_its_queue_without_recounting_its_batch
    @flow = Wurk::Flow.new { |f| f.job(FlowScheduledNodeJob, 1, queue: @queue, at: @at) }.run
    make_due(@flow.jids[0])

    Wurk::Scheduled::Enq.new(Wurk.configuration).enqueue_jobs(['schedule'])

    assert_equal([@flow.jids[0]], queued.map { |j| j['jid'] })
    assert_equal %w[1 1], batch(@flow.bids[0]).values_at('total', 'pending')
  end

  def test_a_dependent_declared_with_at_is_scheduled_when_released
    @flow = Wurk::Flow.new do |f|
      first = f.job(FlowScheduledNodeJob, 1, queue: @queue)
      f.job(FlowScheduledNodeJob, 2, queue: @queue, depends_on: first, at: @at)
    end.run

    Wurk::Flow::Completion.new.on_success(nil, { 'fid' => @flow.fid, 'node' => 0 })

    assert_equal [@flow.jids[0]], queued.map { |j| j['jid'] }, 'only the root is on the queue'
    member = member_for(@flow.jids[1])

    refute_nil member, 'the released dependent is deferred to its at'
    assert_in_delta @at, score_of(member), 0.001
    assert_equal [2], JSON.parse(member)['args']
    assert_equal %w[1 1], batch(@flow.bids[1]).values_at('total', 'pending')
  end

  private

  def queued
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |raw| JSON.parse(raw) }
  end

  def member_for(jid)
    @pool.with { |c| c.call('ZRANGE', 'schedule', 0, -1) }.find { |m| m.include?(%("jid":"#{jid}")) }
  end

  def score_of(member) = @pool.with { |c| c.call('ZSCORE', 'schedule', member) }.to_f

  def make_due(jid)
    @pool.with { |c| c.call('ZADD', 'schedule', 'XX', '0', member_for(jid)) }
  end

  def batch(bid)
    raw = @pool.with { |c| c.call('HGETALL', "b-#{bid}") }
    raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
  end

  def live_jids(bid) = @pool.with { |c| c.call('SMEMBERS', "b-#{bid}-jids") }
end
