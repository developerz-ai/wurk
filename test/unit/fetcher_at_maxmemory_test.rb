# frozen_string_literal: true

require_relative '../test_helper'

# The fetcher's way past a Redis at maxmemory, with the refusal stubbed on the
# one command that would see it, so the suite's shared Redis is never filled:
# the scripts themselves run for real. test/integration/maxmemory_drain_test.rb
# does the same against a Redis that is actually full.
class FetcherAtMaxmemoryTest < Wurk::Test::UnitCase
  parallelize_me!

  OOM = RedisClient::OutOfMemoryError.new("OOM command not allowed when used memory > 'maxmemory'.")

  # Refuses the commands a full Redis refuses, passes everything else.
  class FullRedisConnection < SimpleDelegator
    REFUSED = %w[LMOVE BLMOVE ZADD EVALSHA].freeze

    def call(*args, **, &)
      raise OOM if REFUSED.include?(args.first)

      __getobj__.call(*args, **, &)
    end

    def blocking_call(timeout, *args, **, &)
      raise OOM if REFUSED.include?(args.first)

      __getobj__.blocking_call(timeout, *args, **, &)
    end

    def pipelined(**, &)
      __getobj__.pipelined(**) do |pipe|
        yield(FullRedisPipeline.new(pipe))
      end
    end
  end

  class FullRedisPipeline < SimpleDelegator
    def call(*args, **, &)
      raise OOM if FullRedisConnection::REFUSED.include?(args.first)

      __getobj__.call(*args, **, &)
    end
  end

  def setup
    super
    skip 'Dragonfly keeps serving LMOVE at maxmemory and has no allow-oom' if dragonfly?

    @queue_name = "oom-#{Process.pid}-#{object_id}"
    @public_queue = Wurk::Keys.queue(@queue_name)
    @errors = []
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.error_handlers.replace([->(ex, ctx, _cfg) { @errors << [ex.class, ctx[:context]] }])
    @capsule = @config.default_capsule
    @capsule.queues = [@queue_name]
    @config.fetch_poll_interval = 0.01
    @fetcher = Wurk::Fetcher::Reliable.new(@capsule)
    @capsule.fetcher = @fetcher
    @pool = @capsule.redis_pool
    @private_list = Wurk::Fetcher::Reliable.private_queue_name(@public_queue)
    @identity = Wurk::Component.identity
    fill_redis
  end

  def teardown
    return super unless @pool

    @pool.with do |c|
      c.call('DEL', @public_queue, @private_list, @identity)
      c.call('SREM', Wurk::Keys::PROCESSES, @identity)
    end
    @config.reset_redis_pools!
  ensure
    super
  end

  def test_a_full_redis_still_hands_out_jobs_through_the_private_list
    push('job')

    uow = @fetcher.retrieve_work

    assert_equal 'job', uow.job
    assert_equal @private_list, uow.private_queue
    assert_equal @queue_name, uow.queue_name
    assert_equal ['job'], raw { |c| c.call('LRANGE', @private_list, 0, -1) }, 'reliable: not a destructive pop'
    uow.release_claim
  end

  def test_a_claim_keeps_this_process_alive_for_the_reaper_and_the_supervisor
    push('job')

    @fetcher.retrieve_work.release_claim

    assert_equal(1, raw { |c| c.call('SISMEMBER', Wurk::Keys::PROCESSES, @identity) })
    info = Wurk.load_json(raw { |c| c.call('HGET', @identity, 'info') })

    assert_equal @identity, info['identity']
    assert_operator raw { |c| c.call('TTL', @identity) }, :>, 0
    refute_nil(raw { |c| c.call('HGET', @identity, 'beat') })
  end

  def test_an_existing_heartbeat_keeps_its_info_and_its_beat_moves
    raw do |c|
      c.call('HSET', @identity, 'info', '{"tag":"real"}', 'beat', '1.0')
      c.call('SADD', Wurk::Keys::PROCESSES, @identity)
    end

    assert_nil @fetcher.retrieve_work

    assert_equal('{"tag":"real"}', raw { |c| c.call('HGET', @identity, 'info') })
    refute_equal('1.0', raw { |c| c.call('HGET', @identity, 'beat') })
  end

  def test_an_empty_pass_costs_the_wall_clock_a_block_would
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_nil @fetcher.retrieve_work
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.01
  end

  def test_the_refusal_is_reported_once_rather_than_once_per_fetch
    3.times { @fetcher.retrieve_work }

    assert_equal [[RedisClient::OutOfMemoryError, 'Redis is at maxmemory: draining with allow-oom scripts']], @errors
  end

  # A held ACK has nothing to ride while every fetch is refused, and LREM is one
  # command a full Redis still takes.
  def test_held_acks_are_flushed_on_the_way
    push('done')
    uow = @fetcher.retrieve_work
    uow.acknowledge
    uow.release_claim

    assert_nil @fetcher.retrieve_work
    assert_equal(0, raw { |c| c.call('LLEN', @private_list) })
  end

  # A server that cannot run the script (Dragonfly refuses the shebang) behaves
  # exactly as it did without any of this: the refusal surfaces to the fetch loop.
  def test_a_server_that_refuses_the_script_raises_the_original_refusal
    push('job')
    conn = raw { |c| c }
    refusing = Class.new(SimpleDelegator) do
      def call(*args, **, &)
        raise RedisClient::CommandError, "ERR user_script:1: unexpected symbol near '#'" if args.first == 'EVAL'

        __getobj__.call(*args, **, &)
      end
    end.new(conn)
    error = RedisClient::OutOfMemoryError.new('OOM original')

    raised = assert_raises(RedisClient::OutOfMemoryError) do
      Wurk::Fetcher::OomDrain.reclaim(refusing, error, @public_queue, @private_list)
    end
    assert_same error, raised
  end

  def test_a_dropped_connection_is_not_mistaken_for_an_unsupported_server
    conn = Class.new do
      def call(*) = raise(RedisClient::ConnectionError, 'gone')
    end.new

    assert_raises(RedisClient::ConnectionError) { Wurk::Fetcher::OomDrain.reclaim(conn, OOM, 'a', 'b') }
  end

  def test_a_capped_queue_is_not_claimed_past_its_cap
    @config.global_concurrency = { @queue_name => 1 }
    fetcher = Wurk::Fetcher::Reliable.new(@capsule)
    push('job')

    assert_raises(RedisClient::OutOfMemoryError) { fetcher.retrieve_work }
    assert_equal(1, raw { |c| c.call('LLEN', @public_queue) })
  end

  private

  # Dragonfly compiles no `#!lua` header, so the scripts cannot run, and it keeps
  # serving LMOVE at its own maxmemory, so nothing here is reached in production.
  def dragonfly?
    client = RedisClient.config(url: Wurk::Test.redis_url).new_client
    client.call('INFO', 'server').include?('dragonfly_version')
  ensure
    client&.close
  end

  # Every checkout from the capsule sees a full Redis.
  def fill_redis
    capsule = @capsule
    real = capsule.method(:redis)
    real_fetch = capsule.method(:fetch_redis)
    capsule.define_singleton_method(:redis) do |**kw, &blk|
      real.call(**kw) { |c| blk.call(FullRedisConnection.new(c)) }
    end
    capsule.define_singleton_method(:fetch_redis) do |**kw, &blk|
      real_fetch.call(**kw) { |c| blk.call(FullRedisConnection.new(c)) }
    end
    @real = real
  end

  def raw(&) = @real.call(&)
  def push(payload) = raw { |c| c.call('LPUSH', @public_queue, payload) }
end
