# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/preflight/redis_guard'

# The guard `wurk boot-check` and `wurk preflight --app` put on every Wurk pool
# while the app boots. Real Redis: the proof is that a key is not written.
class PreflightRedisGuardTest < Wurk::Test::UnitCase
  parallelize_me!

  Guard = Wurk::Preflight::RedisGuard

  # A host middleware, to show the guard is added next to it rather than over it.
  module CountingMiddleware
    def call(command, config)
      (Thread.current[:guard_test_seen] ||= []) << command.first
      super
    end
  end

  def setup
    super
    @redis = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    Guard.uninstall
    @pool&.disconnect!
    @redis&.close
    Thread.current[:guard_test_seen] = nil
  ensure
    super
  end

  def test_closed_opens_no_connection_and_names_the_caller
    Guard.install(:closed, label: 'wurk boot-check')
    @pool = pool

    error = assert_raises(Guard::Refused) { @pool.with { |conn| conn.call('SET', 'guard:closed', '1') } }

    assert_match(/\Awurk boot-check: #{Regexp.escape(__FILE__)}:\d+ opened a Redis connection/, error.message)
    assert_includes error.message, 'pass --redis'
    assert_nil @redis.call('GET', 'guard:closed')
  end

  def test_closed_refuses_method_style_commands_too
    Guard.install(:closed, label: 'wurk boot-check')
    @pool = pool
    @redis.call('SET', 'guard:keep', '1')

    assert_raises(Guard::Refused) { @pool.with(&:flushdb) }
    assert_equal '1', @redis.call('GET', 'guard:keep')
  end

  def test_read_only_reads_and_refuses_writes
    Guard.install(:read_only, label: 'wurk boot-check')
    @pool = pool
    @redis.call('SET', 'guard:read', 'v')

    assert_equal('v', @pool.with { |conn| conn.call('GET', 'guard:read') })
    assert @pool.info['redis_version']
    error = assert_raises(Guard::Refused) { @pool.with { |conn| conn.call('DEL', 'guard:read') } }

    assert_match(/sent DEL while the app booted, and wurk boot-check sends only reads/, error.message)
    assert_equal 'v', @redis.call('GET', 'guard:read')
  end

  def test_read_only_refuses_a_pipeline_holding_one_write
    Guard.install(:read_only, label: 'wurk boot-check')
    @pool = pool

    assert_raises(Guard::Refused) do
      @pool.with { |conn| conn.pipelined { |pipe| [pipe.call('GET', 'a'), pipe.call('SET', 'guard:pipe', '1')] } }
    end
    assert_nil @redis.call('GET', 'guard:pipe')
  end

  def test_read_only_lets_the_handshake_through_but_not_other_client_commands
    assert Guard.allowed?(%w[CLIENT SETNAME x])
    assert Guard.allowed?(%w[HELLO 3])
    refute Guard.allowed?(%w[CLIENT KILL ID 1])
    refute Guard.allowed?(%w[DEL key])
  end

  def test_the_guard_runs_next_to_a_host_middleware
    Guard.install(:read_only, label: 'wurk boot-check')
    @pool = pool(middlewares: [CountingMiddleware])

    @pool.with { |conn| conn.call('GET', 'a') }

    assert_raises(Guard::Refused) { @pool.with { |conn| conn.call('SET', 'a', '1') } }
    assert_includes Thread.current[:guard_test_seen], 'GET'
  end

  def test_uninstall_leaves_later_pools_unguarded
    Guard.install(:closed, label: 'wurk boot-check')
    Guard.uninstall
    @pool = pool

    @pool.with { |conn| conn.call('SET', 'guard:free', '1') }

    assert_equal '1', @redis.call('GET', 'guard:free')
  end

  private

  def pool(**) = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, reconnect_attempts: 0, **)
end
