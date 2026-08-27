# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Plan 03/S3. A push is several Redis round trips — one pipeline per queue
# group, then the batched BATCH_PUSH pipeline — so a connection that dies
# mid-push leaves part of the payload set already written. Wurk::Client records
# each group it got a reply for (Client::DELIVERED_KEY) and Buffered re-buffers
# only the rest; without that, the reliable_push replay enqueues a second copy
# of every job the failed push already delivered.
#
# Buffered prepends into Wurk::Client process-globally, so a class-level mutex
# serializes this class's own methods; other test classes still run in parallel.
class ClientPartialDeliveryTest < Wurk::Test::UnitCase
  parallelize_me!

  MUTEX = Mutex.new

  def run(*args, &)
    MUTEX.synchronize { super }
  end

  def setup
    super
    @pool        = Wurk.configuration.redis_pool
    @class_name  = "PartialJob@#{Process.pid}-#{object_id}"
    @queue       = "pd-a-#{Process.pid}-#{object_id}"
    @other_queue = "pd-b-#{Process.pid}-#{object_id}"
    Wurk::Client.reliable_push!
    Wurk::Client::Buffered.reset!
  end

  def teardown
    Wurk::Client.reliable_push_drainer_stop!
    Wurk::Client::Buffered.reset!
    @raw_conn&.close
  ensure
    super
  end

  # The plain LPUSH pipeline lands, the batched BATCH_PUSH pipeline behind it
  # loses the socket. The plain job is in Redis — re-buffering it would double
  # it on the next drain.
  def test_delivered_plain_payloads_do_not_buffer_when_the_batched_phase_fails
    client = Wurk::Client.new(pool: dropping_pool(deliver: 1))
    payloads = [item(args: ['plain'], jid: 'j-plain'),
                item(args: ['batched'], jid: 'j-batched', extra: { 'bid' => 'B-partial' })]

    assert_raises(RedisClient::ConnectionError) { client.send(:raw_push, payloads) }

    assert_equal 0, Wurk::Client::Buffered.buffer_size
    assert_equal [['plain']], queued_args(@queue)
  end

  # Same shape on the scheduled path: the ZADD for the plain jobs lands, the
  # BATCH_SCHEDULE pipeline behind it fails.
  def test_delivered_scheduled_payloads_do_not_buffer_when_the_batched_phase_fails
    client = Wurk::Client.new(pool: dropping_pool(deliver: 1))
    at = ::Process.clock_gettime(::Process::CLOCK_REALTIME) + 3_600
    payloads = [item(args: ['sched'], jid: 'j-sched', extra: { 'at' => at }),
                item(args: ['sched-b'], jid: 'j-sched-b', extra: { 'at' => at, 'bid' => 'B-partial' })]

    assert_raises(RedisClient::ConnectionError) { client.send(:raw_push, payloads) }

    assert_equal 0, Wurk::Client::Buffered.buffer_size
    assert_equal ['j-sched'], scheduled_jids
  end

  # A push spanning two queues that dies between the groups: the first queue's
  # LPUSH is confirmed, the second never went out. Only the second buffers, and
  # the error is absorbed because that payload is now the buffer's problem.
  def test_only_the_undelivered_queue_group_buffers_on_a_multi_queue_push
    client = Wurk::Client.new(pool: dropping_pool(deliver: 1))

    client.send(:raw_push, [item(args: ['a'], jid: 'j-a'),
                            item(args: ['b'], jid: 'j-b', queue: @other_queue)])

    assert_equal [['b']], buffered_args
    assert_equal [['a']], queued_args(@queue)
    assert_empty queued_args(@other_queue)
    # Per-group pipelining registers each queue with its own SADD, so the
    # group that never went out is absent from `queues` too.
    assert_equal [@queue], registered_queues
  end
  # rubocop:enable Minitest/MultipleAssertions

  # The point of the whole exercise: a push that dies partway through two
  # queues and a batch, replayed against a healthy Redis, leaves every job in
  # existence exactly once.
  # rubocop:disable-next Minitest/MultipleAssertions
  def test_drain_after_partial_delivery_enqueues_each_job_exactly_once
    client = Wurk::Client.new(pool: dropping_pool(deliver: 1))
    payloads = [item(args: ['a'], jid: 'j-a'),
                item(args: ['b'], jid: 'j-b', queue: @other_queue),
                item(args: ['batched'], jid: 'j-bat', extra: { 'bid' => 'B-partial' })]

    assert_raises(RedisClient::ConnectionError) { client.send(:raw_push, payloads) }

    Wurk::Client.new(pool: @pool).push(item(args: ['c'], jid: 'j-c'))

    assert_equal 0, Wurk::Client::Buffered.buffer_size
    assert_equal [['a'], ['c']], queued_args(@queue).reverse
    assert_equal [['b']], queued_args(@other_queue)
  end

  # Nothing acknowledged — the pre-existing behavior has to survive: every
  # bidless payload buffers, whatever queue it was headed for.
  def test_a_push_that_delivered_nothing_still_buffers_every_bidless_payload
    client = Wurk::Client.new(pool: dropping_pool(deliver: 0))

    client.send(:raw_push, [item(args: ['a'], jid: 'j-a'),
                            item(args: ['b'], jid: 'j-b', queue: @other_queue)])

    assert_equal [['a'], ['b']], buffered_args
    assert_empty queued_args(@queue)
  end

  # Plan 04/F5 follow-up, through a real RedisPool this time. CannotConnectError
  # is the pool's "provably nothing applied" case — true of the command that
  # raised, false of the pipeline before it. Replaying the block would put the
  # delivered group in `queue:` a second time.
  def test_the_pool_does_not_replay_a_push_that_already_delivered_a_queue_group
    client = Wurk::Client.new(pool: retrying_pool(deliver: 1, kind: RedisClient::CannotConnectError))

    client.send(:raw_push, [item(args: ['a'], jid: 'j-a'),
                            item(args: ['b'], jid: 'j-b', queue: @other_queue)])

    assert_equal [['a']], queued_args(@queue), 'the delivered group must not be re-pushed'
    assert_equal [['b']], buffered_args
  end

  # Plan 03/S14. raw_push hands back exactly what it diverted into the buffer,
  # and Client#push subtracts that from the enqueued metric. The delivered
  # group must not be in the set — it reached Redis and has to keep counting.
  def test_raw_push_returns_only_the_payloads_it_buffered
    client = Wurk::Client.new(pool: dropping_pool(deliver: 1))
    delivered = item(args: ['a'], jid: 'j-a')
    lost      = item(args: ['b'], jid: 'j-b', queue: @other_queue)

    buffered = client.send(:raw_push, [delivered, lost])

    assert_same lost, buffered.first
    assert_equal 1, buffered.size
  end

  # A push that lost nothing reports nothing, so the metric path stays on its
  # allocation-free branch.
  def test_raw_push_returns_nil_when_everything_lands
    assert_nil Wurk::Client.new(pool: @pool).send(:raw_push, [item(args: ['a'], jid: 'j-a')])
  end

  # The ledger must not outlive its push: a later failure that delivered
  # nothing has to buffer in full, not read the previous call's confirmations.
  def test_delivery_ledger_does_not_leak_into_the_next_push
    client = Wurk::Client.new(pool: dropping_pool(deliver: 1))
    payload = item(args: ['a'], jid: 'j-a')
    client.send(:raw_push, [payload, item(args: ['b'], jid: 'j-b', queue: @other_queue)])
    Wurk::Client::Buffered.reset!

    Wurk::Client.new(pool: dropping_pool(deliver: 0)).send(:raw_push, [payload])

    assert_equal [['a']], buffered_args
    assert_nil Thread.current[Wurk::Client::DELIVERED_KEY]
  end

  private

  def item(args:, jid:, queue: @queue, extra: {})
    { 'class' => @class_name, 'args' => args, 'queue' => queue, 'jid' => jid }.merge(extra)
  end

  def buffered_args
    Wurk::Client::Buffered.buffer.map { |p| p['args'] }
  end

  def queued_args(queue)
    @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, -1) }.map { |s| JSON.parse(s)['args'] }
  end

  def registered_queues
    @pool.with { |c| c.call('SMEMBERS', 'queues') }
  end

  def scheduled_jids
    @pool.with { |c| c.call('ZRANGE', 'schedule', 0, -1) }.map { |s| JSON.parse(s)['jid'] }
  end

  # Pool whose connection accepts `deliver` pipelines for real and then behaves
  # like a dropped socket. Reproduces the only failure mode that matters here:
  # writes Redis already applied, followed by a ConnectionError.
  #
  # Deliberately not a RedisPool: these cases are about the delivery ledger, not
  # the retry policy, and a bare pool keeps them free of both.
  def dropping_pool(deliver:)
    conn = MidPushDropConn.new(raw_conn, deliver: deliver)
    pool = Object.new
    pool.define_singleton_method(:with) { |&blk| blk.call(conn) }
    pool
  end

  # The same connection behind a real RedisPool, so the block runs under the
  # actual retry policy. Its own ConnectionPool is swapped out rather than
  # opened, exactly like the pool unit tests do.
  def retrying_pool(deliver:, kind:)
    conn = MidPushDropConn.new(raw_conn, deliver: deliver, kind: kind)
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, name: 'partial')
    pool.instance_variable_set(:@pool, SingleConnPool.new(conn))
    pool
  end

  # Stand-in ConnectionPool that always yields the one faulted connection.
  class SingleConnPool
    def initialize(conn)
      @conn = conn
    end

    def with
      yield @conn
    end

    def shutdown(&); end
  end

  # Bare connection, built the way RedisPool#build_client builds one, against
  # this worker's own Redis DB.
  def raw_conn
    @raw_conn ||= Wurk::RedisClientAdapter::CompatClient.new(
      RedisClient.config(url: Wurk::Test.redis_url).new_client
    )
  end

  # Lands `deliver` pipelines for real, drops the socket on the next one, then
  # recovers — what redis-client's mid-block re-dial looks like from above. A
  # block that replays after the drop therefore re-applies what it already sent,
  # which is the duplicate the pool has to refuse.
  class MidPushDropConn
    def initialize(real, deliver:, kind: RedisClient::ConnectionError)
      @real = real
      @deliver = deliver
      @kind = kind
      @seen = 0
    end

    def pipelined(&)
      @seen += 1
      raise @kind, 'simulated mid-push drop' if @seen == @deliver + 1

      @real.pipelined(&)
    end

    def call(*, &)
      @real.call(*, &)
    end

    # Pass-through, so the odometer RedisPool's replay guard reads is the real
    # connection's count of what actually landed.
    def round_trips
      @real.round_trips
    end
  end
end
