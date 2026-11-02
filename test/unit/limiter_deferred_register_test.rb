# frozen_string_literal: true

require_relative '../test_helper'

# A limiter built at class load must not turn a Redis that is down, LOADING or
# out of memory into a failed `require`, which is a process exit at boot.
class LimiterDeferredRegisterTest < Wurk::Test::UnitCase
  def setup
    super
    @name = "defer-#{Process.pid}-#{object_id}"
    Wurk::Limiter.reset_config!
    @good = Wurk::RedisPool.new(size: 2, url: Wurk::Test.redis_url, timeout: 2, name: 'defer')
    @good.with { |c| Wurk::Lua::Loader.script_load_all(c) }
  end

  def teardown
    Wurk::Limiter.reset_config!
    @good&.disconnect!
    @bad&.disconnect!
  ensure
    super
  end

  def test_construction_survives_unreachable_redis_and_registers_on_first_use
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    @bad = Wurk::RedisPool.new(size: 1, url: "redis://127.0.0.1:#{port}/0", timeout: 1, name: 'defer-bad')
    Wurk::Limiter.config.redis = @bad

    limiter = Wurk::Limiter.concurrent(@name, 1, wait_timeout: 0)

    Wurk::Limiter.config.redis = @good
    ran = false
    limiter.within_limit { ran = true }

    assert ran
    assert_equal(1, @good.with { |c| c.call('EXISTS', "lmtr:#{@name}") })
  end

  def test_healthy_redis_registers_at_construction
    Wurk::Limiter.config.redis = @good
    Wurk::Limiter.concurrent(@name, 1, wait_timeout: 0)

    assert_equal(1, @good.with { |c| c.call('EXISTS', "lmtr:#{@name}") })
  end
end
