# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Drives Wurk::Client::Buffered against real Redis. Simulates Redis-outage
# behavior by routing pushes through a fake pool that raises
# RedisClient::ConnectionError. Verifies: (a) push returns a jid even on
# outage, (b) on next push the buffer drains oldest-first, (c) cap eviction
# behavior, (d) batched payloads bypass the buffer and raise immediately.
#
# Mutates global state on Wurk::Client (prepends InstanceMethods once; resets
# the buffer between tests). Opts into the parallel runner per the project
# contract, but a class-level mutex around #run serializes execution *within*
# this class so the global Client/Buffered singleton state can't race. Other
# test classes still run in parallel with this one.
class ClientBufferedTest < Wurk::Test::UnitCase
  parallelize_me!

  MUTEX = Mutex.new

  def run(*args, &)
    MUTEX.synchronize { super }
  end

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @class_name = "BufferedJob@#{Process.pid}-#{object_id}"
    @queue      = "bq-#{Process.pid}-#{object_id}"
    Wurk::Client.reliable_push!
    Wurk::Client::Buffered.reset!
  end

  def teardown
    Wurk::Client::Buffered.reset!
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue) if @queue
    end
  ensure
    super
  end

  # --- activation & config ----------------------------------------------

  def test_reliable_push_is_idempotent
    Wurk::Client.reliable_push!
    Wurk::Client.reliable_push!

    assert_predicate Wurk::Client, :reliable_push?
  end

  def test_default_buffer_cap_is_1000
    assert_equal 1_000, Wurk::Client::Buffered::DEFAULT_BUFFER_CAP
    assert_equal 1_000, Wurk::Client.reliable_push_buffer
  end

  def test_reliable_push_buffer_setter_accepts_positive_integer
    Wurk::Client.reliable_push_buffer = 50

    assert_equal 50, Wurk::Client.reliable_push_buffer
  end

  def test_reliable_push_buffer_rejects_non_positive
    assert_raises(ArgumentError) { Wurk::Client.reliable_push_buffer = 0 }
    assert_raises(ArgumentError) { Wurk::Client.reliable_push_buffer = -1 }
    assert_raises(ArgumentError) { Wurk::Client.reliable_push_buffer = 'big' }
  end

  # --- buffer on outage --------------------------------------------------

  def test_push_buffers_payload_on_connection_error
    client = build_client(failing_pool)
    jid = client.push(base_item)

    assert_match(/\A[0-9a-f]{24}\z/, jid)
    assert_equal 1, Wurk::Client::Buffered.buffer_size
  end

  def test_push_returns_jid_even_when_buffered
    client = build_client(failing_pool)

    refute_nil client.push(base_item)
  end

  def test_push_bulk_buffers_all_payloads_on_outage
    client = build_client(failing_pool)
    client.push_bulk(base_item('args' => [[1], [2], [3]]))

    assert_equal 3, Wurk::Client::Buffered.buffer_size
  end

  def test_buffered_payloads_drain_on_next_successful_push
    failing = build_client(failing_pool)
    3.times { |i| failing.push(base_item('args' => [i])) }

    assert_equal 3, Wurk::Client::Buffered.buffer_size

    good = Wurk::Client.new
    good.push(base_item('args' => [99]))

    assert_equal 0, Wurk::Client::Buffered.buffer_size
    # 3 buffered + 1 new = 4 jobs in queue
    assert_equal 4, queue_length
  end

  def test_drain_preserves_oldest_first_order
    failing = build_client(failing_pool)
    failing.push(base_item('args' => ['first']))
    failing.push(base_item('args' => ['second']))
    failing.push(base_item('args' => ['third']))

    Wurk::Client.new.push(base_item('args' => ['fourth']))

    # LPUSH puts newest at head → reversing gives push order:
    assert_equal [['first'], ['second'], ['third'], ['fourth']], queued_args.reverse
  end

  def test_drain_emits_statsd_per_job
    calls = with_statsd_capture do
      failing = build_client(failing_pool)
      failing.push(base_item)
      failing.push(base_item)
      Wurk::Client.new.push(base_item)
    end

    assert_equal %w[jobs.recovered.push jobs.recovered.push], calls
  end

  # --- ring cap ----------------------------------------------------------

  def test_buffer_drops_oldest_when_cap_exceeded
    Wurk::Client.reliable_push_buffer = 2
    failing = build_client(failing_pool)
    failing.push(base_item('args' => ['oldest']))
    failing.push(base_item('args' => ['middle']))
    failing.push(base_item('args' => ['newest']))

    assert_equal 2, Wurk::Client::Buffered.buffer_size
  end

  # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
  def test_drain_after_cap_eviction_replays_surviving_entries
    Wurk::Client.reliable_push_buffer = 2
    failing = build_client(failing_pool)
    failing.push(base_item('args' => ['oldest']))
    failing.push(base_item('args' => ['middle']))
    failing.push(base_item('args' => ['newest']))

    Wurk::Client.new.push(base_item('args' => ['fresh']))

    queued = queued_args

    refute_includes queued, ['oldest']
    assert_includes queued, ['middle']
    assert_includes queued, ['newest']
    assert_includes queued, ['fresh']
  end
  # rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions

  # --- batch bypass ------------------------------------------------------

  def test_batched_payload_does_not_buffer_and_re_raises
    client = build_client(failing_pool)

    assert_raises(RedisClient::ConnectionError) do
      client.push(base_item('bid' => 'B12345'))
    end
    assert_equal 0, Wurk::Client::Buffered.buffer_size
  end

  # --- partial drain on persistent outage --------------------------------

  def test_drain_re_buffers_payload_when_redis_still_down
    failing = build_client(failing_pool)
    failing.push(base_item('args' => [1]))
    failing.push(base_item('args' => [2]))

    # Next push also fails — buffer should preserve head order, no dupes.
    failing.push(base_item('args' => [3]))

    assert_equal 3, Wurk::Client::Buffered.buffer_size
    assert_equal [[1], [2], [3]], Wurk::Client::Buffered.buffer.map { |p| p['args'] } # rubocop:disable Lint/AmbiguousBlockAssociation
  end

  private

  # Statsd singletons are process-global — serialize against every other test
  # class that also rewrites `Wurk::Metrics::Statsd.increment`.
  def with_statsd_capture
    Wurk::Test::STATSD_MUTEX.synchronize do
      calls = []
      Wurk::Metrics::Statsd.singleton_class.alias_method(:__increment_real, :increment)
      Wurk::Metrics::Statsd.define_singleton_method(:increment) { |metric, **| calls << metric }
      begin
        yield
        calls
      ensure
        Wurk::Metrics::Statsd.singleton_class.send(:alias_method, :increment, :__increment_real)
        Wurk::Metrics::Statsd.singleton_class.send(:remove_method, :__increment_real)
      end
    end
  end

  def base_item(overrides = {})
    { 'class' => @class_name, 'args' => [], 'queue' => @queue }.merge(overrides)
  end

  def build_client(pool)
    Wurk::Client.new(pool: pool)
  end

  # Pool that yields a connection always raising ConnectionError on the
  # pipelined write path Wurk::Client#raw_push uses.
  def failing_pool
    pool = Object.new
    pool.define_singleton_method(:with) do |&blk|
      blk.call(FailingConn.new)
    end
    pool
  end

  def queued_payloads
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |s| JSON.parse(s) }
  end

  def queued_args
    queued_payloads.map { |p| p['args'] }
  end

  def queue_length
    @pool.with { |c| c.call('LLEN', "queue:#{@queue}") }
  end

  # Fake connection that raises on any pipeline operation. Mimics a dead
  # socket: pipelined block runs, the first call inside raises.
  class FailingConn
    def pipelined
      yield self
    end

    def call(*)
      raise RedisClient::ConnectionError, 'simulated outage'
    end
  end
end
