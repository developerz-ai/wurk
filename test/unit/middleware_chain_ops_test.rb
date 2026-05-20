# frozen_string_literal: true

require_relative '../test_helper'

# Coverage for the `Wurk::Middleware::ServerMiddleware` / `ClientMiddleware`
# contract module: config setter, plus convenience accessors delegating to the
# bound config. The Chain integration (config assignment via Entry#make_new)
# is exercised in middleware_chain_test.rb.
class MiddlewareChainOpsTest < Wurk::Test::UnitCase
  parallelize_me!

  # Fake config that quacks like Wurk::Capsule for the three accessors we
  # care about. Returning sentinel objects lets the assertions identity-check
  # to prove the delegation is unwrapped (no caching/copying).
  class FakeConfig
    attr_reader :redis_pool, :logger, :redis_block

    def initialize(redis_pool: Object.new, logger: Object.new)
      @redis_pool = redis_pool
      @logger = logger
    end

    def redis
      @redis_block = true
      yield :conn
    end
  end

  class ServerEx
    include Wurk::Middleware::ServerMiddleware
  end

  class ClientEx
    include Wurk::Middleware::ClientMiddleware
  end

  def test_client_middleware_is_server_middleware
    assert_same Wurk::Middleware::ServerMiddleware, Wurk::Middleware::ClientMiddleware
  end

  def test_config_attr_accessor
    instance = ServerEx.new
    cfg = FakeConfig.new

    assert_nil instance.config
    instance.config = cfg

    assert_same cfg, instance.config
  end

  def test_redis_pool_delegates_to_config
    pool = Object.new
    instance = ServerEx.new
    instance.config = FakeConfig.new(redis_pool: pool)

    assert_same pool, instance.redis_pool
  end

  def test_logger_delegates_to_config
    log = Object.new
    instance = ServerEx.new
    instance.config = FakeConfig.new(logger: log)

    assert_same log, instance.logger
  end

  def test_redis_yields_through_config
    cfg = FakeConfig.new
    instance = ServerEx.new
    instance.config = cfg
    seen = nil
    instance.redis { |c| seen = c }

    assert_equal :conn, seen
    assert cfg.redis_block
  end

  def test_chain_assigns_config_to_middleware_instances
    cfg = FakeConfig.new
    chain = Wurk::Middleware::Chain.new(cfg)
    chain.add(ClientEx)
    instance = chain.retrieve.first

    assert_same cfg, instance.config
  end
end
