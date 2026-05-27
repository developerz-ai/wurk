# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Issue #19 DoD coverage. The togglable pool stands in for the real outage
# because `redis-cli SHUTDOWN` / `DEBUG SLEEP` would race every parallel
# sibling against the shared test Redis. Drain + LRANGE assertions still
# round-trip through the live server.
class ClientOutageTest < Wurk::Test::UnitCase
  parallelize_me!

  # Buffered installs InstanceMethods globally; serialize within this class
  # so the singleton buffer/drainer state can't race sibling tests.
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

  # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
  def test_producer_through_redis_outage_preserves_all_jobs_in_order
    pool   = TogglablePool.new(@real_pool)
    client = Wurk::Client.new(pool: pool)

    client.push(item(tag: '1'))

    pool.fail!
    %w[2 3 4].each { |t| client.push(item(tag: t)) }

    assert_equal 3, Wurk::Client::Buffered.buffer_size, 'all 3 outage pushes must buffer'

    pool.recover!
    client.push(item(tag: '5'))

    assert_equal 0, Wurk::Client::Buffered.buffer_size

    queued = @real_pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }
    tags = queued.map { |s| JSON.parse(s)['args'].first }.reverse

    assert_equal %w[1 2 3 4 5], tags
  end
  # rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions

  # The producer-stops case the background drainer exists for — without it,
  # the passive drain-on-next-push path never fires.
  # rubocop:disable Metrics/AbcSize
  def test_background_drainer_flushes_when_pool_recovers_without_new_push
    pool = TogglablePool.new(@real_pool)
    client = Wurk::Client.new(pool: pool)

    pool.fail!
    %w[a b c].each { |t| client.push(item(tag: t)) }

    assert_equal 3, Wurk::Client::Buffered.buffer_size

    Wurk::Client::Buffered.start_drainer!(interval: 0.02)
    # Drainer's default factory uses the global config pool; redirect to
    # @real_pool so recovery lands in the queue we assert on.
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

  class FailingConn
    def pipelined
      yield self
    end

    def call(*)
      raise RedisClient::ConnectionError, 'simulated outage'
    end
  end
end
