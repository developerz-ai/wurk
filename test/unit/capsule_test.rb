# frozen_string_literal: true

require_relative '../test_helper'

class CapsuleTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    @config = Wurk::Configuration.new
    @capsule = Wurk::Capsule.new('default', @config)
  end

  def teardown
    @capsule.instance_variable_get(:@redis_pool)&.disconnect!
    @capsule.instance_variable_get(:@local_redis_pool)&.disconnect!
  rescue ConnectionPool::PoolShuttingDownError
    # already torn down
  ensure
    super
  end

  # --- defaults ----------------------------------------------------------

  def test_default_name_is_string
    assert_equal 'default', @capsule.name
  end

  def test_default_concurrency_inherits_from_config
    assert_equal @config[:concurrency], @capsule.concurrency
  end

  def test_default_queues
    assert_equal ['default'], @capsule.queues
  end

  def test_default_mode_is_strict
    assert_equal :strict, @capsule.mode
  end

  def test_default_weights
    assert_equal({ 'default' => 0 }, @capsule.weights)
  end

  def test_to_h_emits_concurrency_mode_weights
    h = @capsule.to_h

    assert_equal @capsule.concurrency, h[:concurrency]
    assert_equal @capsule.mode, h[:mode]
    assert_equal @capsule.weights, h[:weights]
  end

  # --- queues= parsing ---------------------------------------------------

  def test_queues_setter_strict_mode_for_plain_names
    @capsule.queues = %w[high default low]

    assert_equal :strict, @capsule.mode
    assert_equal %w[high default low], @capsule.queues
    assert_equal({ 'high' => 0, 'default' => 0, 'low' => 0 }, @capsule.weights)
  end

  def test_queues_setter_weighted_mode
    @capsule.queues = %w[high,3 default,2 low,1]

    assert_equal :weighted, @capsule.mode
    assert_equal({ 'high' => 3, 'default' => 2, 'low' => 1 }, @capsule.weights)
    assert_equal %w[high high high default default low], @capsule.queues
  end

  def test_queues_setter_random_mode_when_all_weights_equal_one
    @capsule.queues = %w[a,1 b,1 c,1]

    assert_equal :random, @capsule.mode
    assert_equal({ 'a' => 1, 'b' => 1, 'c' => 1 }, @capsule.weights)
    assert_equal %w[a b c], @capsule.queues
  end

  def test_queues_setter_rejects_empty_array
    assert_raises(ArgumentError) { @capsule.queues = [] }
  end

  def test_queues_setter_accepts_single_string
    @capsule.queues = ['high']

    assert_equal :strict, @capsule.mode
    assert_equal ['high'], @capsule.queues
  end

  def test_queues_setter_raises_on_non_integer_weight
    assert_raises(ArgumentError) { @capsule.queues = ['high,foo'] }
  end

  # --- concurrency setter ------------------------------------------------

  def test_concurrency_is_writable
    @capsule.concurrency = 25

    assert_equal 25, @capsule.concurrency
  end

  # --- middleware --------------------------------------------------------

  def test_client_middleware_returns_chain
    assert_kind_of Wurk::Middleware::Chain, @capsule.client_middleware
  end

  def test_client_middleware_yields_chain
    yielded = nil
    @capsule.client_middleware { |chain| yielded = chain }

    assert_same @capsule.client_middleware, yielded
  end

  def test_server_middleware_yields_chain
    yielded = nil
    @capsule.server_middleware { |chain| yielded = chain }

    assert_same @capsule.server_middleware, yielded
  end

  # --- redis pools -------------------------------------------------------

  def test_redis_pool_size_matches_concurrency
    @capsule.concurrency = 7

    assert_equal 7, @capsule.redis_pool.size
  end

  def test_redis_pool_is_memoized
    assert_same @capsule.redis_pool, @capsule.redis_pool
  end

  def test_local_redis_pool_size_matches_concurrency
    @capsule.concurrency = 4

    assert_equal 4, @capsule.local_redis_pool.size
  end

  def test_redis_pool_and_local_pool_are_distinct
    refute_same @capsule.redis_pool, @capsule.local_redis_pool
  end

  def test_redis_pool_url_from_config
    @config.redis = { url: 'redis://127.0.0.1:6379/0' }
    cap = Wurk::Capsule.new('x', @config)

    assert_equal 'redis://127.0.0.1:6379/0', cap.redis_pool.url
  ensure
    cap&.redis_pool&.disconnect!
  end

  # --- fetcher slot ------------------------------------------------------

  def test_fetcher_is_settable
    fake = Object.new
    @capsule.fetcher = fake

    assert_same fake, @capsule.fetcher
  end

  def test_fetcher_defaults_to_nil
    assert_nil @capsule.fetcher
  end

  # --- lookup / logger delegation ---------------------------------------

  def test_lookup_delegates_to_config
    obj = Object.new
    @config.register(:thing, obj)

    assert_same obj, @capsule.lookup(:thing)
  end

  def test_logger_delegates_to_config
    custom = ::Logger.new(IO::NULL)
    @config.logger = custom

    assert_same custom, @capsule.logger
  end
end
