# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Issue #19 DoD: "Kill Redis for 10s while a producer pushes → no exceptions;
# on Redis return, all jobs land in correct queue in order."
#
# Simulates a real outage by routing the producer's pushes through a togglable
# pool that swaps between a `FailingConn` (raises RedisClient::ConnectionError
# on every pipelined call, mimicking a dead socket) and the live Redis pool.
# We do NOT bring down the real Redis — that would race every other parallel
# test sharing the instance.
class ClientOutageTest < Wurk::Test::UnitCase
  parallelize_me!

  # Wurk::Client::Buffered installs InstanceMethods globally; tests that
  # toggle activation or mutate the singleton buffer/drainer must serialize
  # within this class.
  MUTEX = Mutex.new

  def run(*args, &)
    MUTEX.synchronize { super }
  end

  def setup
    super
    @real_pool  = Wurk.configuration.redis_pool
    @class_name = "OutageJob@#{Process.pid}-#{object_id}"
    @queue      = "outage-q-#{Process.pid}-#{object_id}"
    Wurk::Client.reliable_push!
    Wurk::Client::Buffered.reset!
  end

  def teardown
    Wurk::Client.reliable_push_drainer_stop!
    Wurk::Client::Buffered.reset!
    @real_pool.with do |c|
      c.call('DEL', "queue:#{@queue}")
      c.call('SREM', 'queues', @queue)
    end
  ensure
    super
  end

  # The DoD scenario. A producer pushes 5 jobs total: 1 before the outage,
  # 3 during, 1 after. Buffered catches the middle 3; the next post-outage
  # push drains them oldest-first then enqueues #5. End state: 5 jobs in
  # the queue in original push order.
  # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
  def test_producer_through_redis_outage_preserves_all_jobs_in_order
    pool   = TogglablePool.new(@real_pool)
    client = Wurk::Client.new(pool: pool)

    # Push #1 — pool is healthy, lands in Redis directly.
    client.push(item(tag: '1'))

    pool.fail!

    # Push #2..#4 during the outage — buffered, no exceptions raised.
    %w[2 3 4].each { |t| client.push(item(tag: t)) }

    assert_equal 3, Wurk::Client::Buffered.buffer_size, 'all 3 outage pushes must buffer'

    pool.recover!

    # Push #5 — drains 2,3,4 then pushes 5.
    client.push(item(tag: '5'))

    assert_equal 0, Wurk::Client::Buffered.buffer_size

    queued = @real_pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }
    tags = queued.map { |s| JSON.parse(s)['args'].first }.reverse

    assert_equal %w[1 2 3 4 5], tags
  end
  # rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions

  # The producer-stops-mid-outage case the background drainer exists for.
  # No further pushes happen after the buffered batch, so the passive
  # drain-on-next-push path would never fire; the drainer thread must.
  # rubocop:disable Metrics/AbcSize
  def test_background_drainer_flushes_when_pool_recovers_without_new_push
    pool = TogglablePool.new(@real_pool)
    client = Wurk::Client.new(pool: pool)

    pool.fail!
    %w[a b c].each { |t| client.push(item(tag: t)) }

    assert_equal 3, Wurk::Client::Buffered.buffer_size

    Wurk::Client::Buffered.start_drainer!(interval: 0.02)
    # Point the drainer at the live pool (its built-in factory uses the
    # global config pool; we want it to recover *into* @real_pool).
    Wurk::Client::Buffered.instance_variable_get(:@drainer).instance_variable_set(
      :@client_factory, -> { Wurk::Client.new(pool: @real_pool) }
    )
    pool.recover!

    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 3.0
    until Wurk::Client::Buffered.buffer_size.zero? || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end

    assert_equal 0, Wurk::Client::Buffered.buffer_size, 'background drainer did not flush within 3s'

    queued = @real_pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }
    tags = queued.map { |s| JSON.parse(s)['args'].first }.reverse

    assert_equal %w[a b c], tags
  end
  # rubocop:enable Metrics/AbcSize

  private

  def item(tag:)
    { 'class' => @class_name, 'args' => [tag], 'queue' => @queue }
  end

  # Toggles between healthy (delegates to the real pool) and failing
  # (yields a connection whose `call` raises ConnectionError on every
  # invocation). Thread-safe — `fail!` / `recover!` only flip an atomic
  # flag read in `with`.
  class TogglablePool
    def initialize(real_pool)
      @real_pool = real_pool
      @failing = false
      @mutex = Mutex.new
    end

    def fail!
      @mutex.synchronize { @failing = true }
    end

    def recover!
      @mutex.synchronize { @failing = false }
    end

    def with(&)
      if @mutex.synchronize { @failing }
        yield FailingConn.new
      else
        @real_pool.with(&)
      end
    end
  end

  # Mimics a dead socket. Raises on every pipelined call.
  class FailingConn
    def pipelined
      yield self
    end

    def call(*)
      raise RedisClient::ConnectionError, 'simulated outage'
    end
  end
end
