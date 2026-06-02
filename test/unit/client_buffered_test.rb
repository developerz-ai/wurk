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
    Wurk::Client.reliable_push_drainer_stop!
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

    assert_equal %w[jobs.recovered.push jobs.recovered.push], calls.grep('jobs.recovered.push')
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

  # --- overflow mode (issue #19, opt-in raise on cap) --------------------

  def test_overflow_mode_default_is_drop_oldest
    assert_equal :drop_oldest, Wurk::Client::Buffered.overflow_mode
    assert_equal :drop_oldest, Wurk::Client.reliable_push_overflow
  end

  def test_overflow_mode_setter_accepts_known_modes
    Wurk::Client.reliable_push_overflow = :raise

    assert_equal :raise, Wurk::Client.reliable_push_overflow

    Wurk::Client.reliable_push_overflow = 'drop_oldest'

    assert_equal :drop_oldest, Wurk::Client.reliable_push_overflow
  end

  def test_overflow_mode_setter_rejects_unknown
    assert_raises(ArgumentError) { Wurk::Client.reliable_push_overflow = :explode }
  end

  def test_overflow_raise_raises_when_cap_reached
    Wurk::Client.reliable_push_buffer = 2
    Wurk::Client.reliable_push_overflow = :raise
    failing = build_client(failing_pool)

    failing.push(base_item('args' => ['first']))
    failing.push(base_item('args' => ['second']))

    err = assert_raises(Wurk::Client::Buffered::Overflow) { failing.push(base_item('args' => ['third'])) }

    assert_equal ['third'], err.payload['args']
    assert_equal 2, Wurk::Client::Buffered.buffer_size, 'buffer untouched by overflow payload'
  end

  def test_overflow_raise_preserves_oldest_when_cap_reached
    Wurk::Client.reliable_push_buffer = 1
    Wurk::Client.reliable_push_overflow = :raise
    failing = build_client(failing_pool)

    failing.push(base_item('args' => ['keep']))
    assert_raises(Wurk::Client::Buffered::Overflow) { failing.push(base_item('args' => ['reject'])) }

    assert_equal [['keep']], Wurk::Client::Buffered.buffer.map { |p| p['args'] } # rubocop:disable Lint/AmbiguousBlockAssociation
  end

  # --- background drainer (issue #19) ------------------------------------

  def test_reliable_push_drainer_starts_thread
    Wurk::Client.reliable_push_drainer(interval: 0.05)

    assert_predicate Wurk::Client, :reliable_push_drainer_running?
  end

  def test_reliable_push_drainer_idempotent_restart
    Wurk::Client.reliable_push_drainer(interval: 0.05)
    first = Wurk::Client::Buffered.instance_variable_get(:@drainer)
    Wurk::Client.reliable_push_drainer(interval: 0.1)
    second = Wurk::Client::Buffered.instance_variable_get(:@drainer)

    refute_same first, second
    assert_predicate Wurk::Client, :reliable_push_drainer_running?
  end

  def test_reliable_push_drainer_stop
    Wurk::Client.reliable_push_drainer(interval: 0.05)
    Wurk::Client.reliable_push_drainer_stop!

    refute_predicate Wurk::Client, :reliable_push_drainer_running?
  end

  # rubocop:disable Metrics/AbcSize
  def test_drainer_drains_buffer_against_recovering_pool
    pool = togglable_pool
    failing_client = build_client(pool.failing_facade)
    failing_client.push(base_item('args' => ['a']))
    failing_client.push(base_item('args' => ['b']))

    assert_equal 2, Wurk::Client::Buffered.buffer_size

    # Background drainer points at the real Redis pool — once it ticks,
    # both queued payloads should land in the live queue.
    Wurk::Client::Buffered.start_drainer!(interval: 0.02)
    Wurk::Client::Buffered.instance_variable_get(:@drainer).instance_variable_set(
      :@client_factory, -> { Wurk::Client.new(pool: @pool) }
    )

    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 3.0
    until Wurk::Client::Buffered.buffer_size.zero? || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end

    assert_equal 0, Wurk::Client::Buffered.buffer_size, 'drainer did not flush buffer within 3s'
    assert_equal [['a'], ['b']], queued_args.reverse
  end
  # rubocop:enable Metrics/AbcSize

  def test_drainer_rejects_non_positive_interval
    assert_raises(ArgumentError) { Wurk::Client::Buffered::Drainer.new(interval: 0) }
    assert_raises(ArgumentError) { Wurk::Client::Buffered::Drainer.new(interval: -1) }
  end

  # start is idempotent: a second start while the thread is alive hits the
  # `return if @thread&.alive?` then-branch and keeps the same thread.
  def test_drainer_start_is_idempotent_while_running
    drainer = idle_drainer
    drainer.start
    first = drainer.instance_variable_get(:@thread)
    drainer.start
    second = drainer.instance_variable_get(:@thread)

    assert_same first, second
    assert_predicate drainer, :running?
  ensure
    drainer.stop
  end

  # stop with no thread ever started exercises the `@thread&.join` nil
  # (else) side and running? `@thread&.alive?` nil (else) side.
  def test_drainer_stop_and_running_with_no_thread
    drainer = idle_drainer

    refute_predicate drainer, :running?
    drainer.stop # must not raise on nil @thread

    refute_predicate drainer, :running?
  end

  # wait_interval's `@wake.wait(...) unless @done` else-side: when @done is
  # already true (stop won the race before the loop parked), the wait is
  # skipped and the method returns immediately rather than parking for the
  # 30s interval. Driven directly so it's deterministic — no thread timing.
  def test_wait_interval_skips_wait_when_already_done
    drainer = Wurk::Client::Buffered::Drainer.new(
      interval: 30.0, client_factory: -> { NoopDrainClient.new }
    )
    drainer.instance_variable_set(:@done, true)

    t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    drainer.send(:wait_interval)
    elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - t0

    assert_operator elapsed, :<, 1.0, 'wait_interval must not park when @done is set'
  end

  # Complementary then-side: @done false → wait_interval parks on the
  # ConditionVariable, and a broadcast (what stop sends) wakes it back up.
  def test_wait_interval_parks_until_broadcast_when_not_done
    drainer = Wurk::Client::Buffered::Drainer.new(
      interval: 30.0, client_factory: -> { NoopDrainClient.new }
    )
    waiter = Thread.new { drainer.send(:wait_interval) }

    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    sleep 0.005 until waiter.status == 'sleep' || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started > 1.0

    assert_equal 'sleep', waiter.status, 'wait_interval should park on the condvar'

    lock = drainer.instance_variable_get(:@lock)
    wake = drainer.instance_variable_get(:@wake)
    lock.synchronize { wake.broadcast }

    assert waiter.join(5.0), 'broadcast should wake the parked wait_interval'
  end

  private

  # Drainer with a long interval and a no-op client so the run loop never
  # touches Redis; lets us assert start/stop/running? control flow directly.
  def idle_drainer
    Wurk::Client::Buffered::Drainer.new(
      interval: 30.0, client_factory: -> { NoopDrainClient.new }
    )
  end

  # Stands in for a Wurk::Client in the drainer's run loop. drain! calls
  # pop_head (empty buffer → nil → no replay), so push is never reached;
  # this just satisfies the factory contract without hitting Redis.
  class NoopDrainClient; end

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

  # A togglable pool wrapper for the drainer integration test. Exposes
  # `failing_facade` for the producer (raises ConnectionError) and the
  # real pool stays untouched for the drainer to recover into.
  def togglable_pool
    real_pool = @pool
    TogglablePoolPair.new(real_pool)
  end

  class TogglablePoolPair
    def initialize(real_pool)
      @real_pool = real_pool
    end

    def failing_facade
      facade = Object.new
      facade.define_singleton_method(:with) { |&blk| blk.call(FailingConn.new) }
      facade
    end
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
