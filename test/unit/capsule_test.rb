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
    @capsule.instance_variable_get(:@fetch_redis_pool)&.disconnect!
  rescue ConnectionPool::PoolShuttingDownError
    # already torn down
  ensure
    super
  end

  # --- middleware binding (#69) ------------------------------------------

  # The capsule must bind its chains via copy_for(self), not a bare dup, so
  # middleware resolve config.redis_pool/redis/logger instead of hitting nil.
  ProbeMiddleware = Class.new do
    include Wurk::Middleware::ServerMiddleware

    def call(*) = yield
  end

  def test_server_middleware_instances_are_bound_to_the_capsule
    @config.server_middleware.add(ProbeMiddleware)

    instance = @capsule.server_middleware.retrieve.find { |m| m.is_a?(ProbeMiddleware) }

    refute_nil instance.config, 'server middleware config must not be nil'
    assert_same @capsule, instance.config
  end

  def test_client_middleware_instances_are_bound_to_the_capsule
    @config.client_middleware.add(ProbeMiddleware)

    instance = @capsule.client_middleware.retrieve.find { |m| m.is_a?(ProbeMiddleware) }

    assert_same @capsule, instance.config
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

  # Manager/Processor/Fetcher pass their capsule to Component as `config`, and
  # safe_thread reads the priority off it.
  def test_thread_priority_delegates_to_config
    assert_equal @config.thread_priority, @capsule.thread_priority

    @config.thread_priority = 0

    assert_equal 0, @capsule.thread_priority
  end

  # --- prepare! / fetcher defaulting (regression #35) -------------------

  def test_prepare_defaults_fetcher_to_reliable
    assert_nil @capsule.fetcher

    @capsule.prepare!

    assert_instance_of Wurk::Fetcher::Reliable, @capsule.fetcher
  end

  def test_prepare_preserves_an_explicit_fetcher
    custom = Wurk::Fetcher::Reliable.new(@capsule)
    @capsule.fetcher = custom

    @capsule.prepare!

    assert_same custom, @capsule.fetcher
  end

  # --- fetch_class / fetch_setup pluggability (#107) --------------------

  # A capsule whose config sets config[:fetch_class] uses it instead of the
  # default reliable fetcher. Spec: sidekiq-free.md §5 (config[:fetch_class]
  # || Sidekiq::BasicFetch).
  StubFetcher = Class.new do
    attr_reader :capsule

    def initialize(capsule)
      @capsule = capsule
    end
  end

  def test_prepare_honors_config_fetch_class
    @config[:fetch_class] = StubFetcher

    @capsule.prepare!

    assert_instance_of StubFetcher, @capsule.fetcher
    assert_same @capsule, @capsule.fetcher.capsule
  end

  def test_prepare_falls_back_to_reliable_without_fetch_class
    assert_nil @config[:fetch_class]

    @capsule.prepare!

    assert_instance_of Wurk::Fetcher::Reliable, @capsule.fetcher
  end

  # config[:fetch_setup] is handed the freshly built fetcher so it can
  # configure it (spec §4.1 fetch_setup callable).
  def test_prepare_invokes_fetch_setup_with_the_built_fetcher
    seen = nil
    @config[:fetch_class] = StubFetcher
    @config[:fetch_setup] = ->(fetcher) { seen = fetcher }

    @capsule.prepare!

    assert_same @capsule.fetcher, seen
  end

  def test_prepare_ignores_non_callable_fetch_setup
    @config[:fetch_setup] = 'not callable'

    @capsule.prepare! # must not raise

    assert_instance_of Wurk::Fetcher::Reliable, @capsule.fetcher
  end

  def test_prepare_materializes_lazy_pools
    @capsule.prepare!

    refute_nil @capsule.instance_variable_get(:@redis_pool)
    refute_nil @capsule.instance_variable_get(:@fetch_redis_pool)
  end

  # --- prepare_shared! (the half a swarm parent runs pre-fork) ----------

  def test_prepare_shared_materializes_the_middleware_chains
    @capsule.prepare_shared!
    @capsule.freeze

    assert_kind_of Wurk::Middleware::Chain, @capsule.client_middleware
    assert_kind_of Wurk::Middleware::Chain, @capsule.server_middleware
  end

  # Slot-dependent and socket-owning state stays behind: pools are sized off
  # the slot's concurrency, and build_fetcher fires the host's per-child
  # config[:fetch_setup] hook.
  def test_prepare_shared_leaves_the_pools_and_fetcher_alone
    @config[:fetch_setup] = ->(_fetcher) { raise 'fetch_setup must not fire before the fork' }

    @capsule.prepare_shared!

    assert_nil @capsule.fetcher
    assert_nil @capsule.instance_variable_get(:@redis_pool)
    assert_nil @capsule.instance_variable_get(:@fetch_redis_pool)
  end

  def test_prepare_completes_what_prepare_shared_left
    @capsule.prepare_shared!

    @capsule.prepare!

    assert_instance_of Wurk::Fetcher::Reliable, @capsule.fetcher
    refute_nil @capsule.instance_variable_get(:@redis_pool)
    refute_nil @capsule.instance_variable_get(:@fetch_redis_pool)
  end

  def test_prepare_shared_returns_self
    assert_same @capsule, @capsule.prepare_shared!
  end

  def test_queue_specs_round_trips_weighted_queues
    @capsule.queues = %w[high,3 default,2]

    assert_equal %w[high,3 default,2], @capsule.queue_specs
  end

  def test_queue_specs_omits_weight_for_strict_queues
    @capsule.queues = %w[high default]

    assert_equal %w[high default], @capsule.queue_specs
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

  # #241: Sidekiq's weighted-queue YAML (`:queues: - [high, 3]`) parses to nested
  # arrays, which used to crash `parse_queue_entry` with `Integer(): " 3]"`.
  def test_queues_setter_accepts_nested_array_weight_pairs
    @capsule.queues = [['high', 3], ['default', 2], ['low', 1]]

    assert_equal :weighted, @capsule.mode
    assert_equal({ 'high' => 3, 'default' => 2, 'low' => 1 }, @capsule.weights)
    assert_equal %w[high high high default default low], @capsule.queues
  end

  # A bare array entry (no weight) is a plain/strict queue, same as a plain string.
  def test_queues_setter_accepts_nested_array_without_weight
    @capsule.queues = [['high'], ['low']]

    assert_equal :strict, @capsule.mode
    assert_equal({ 'high' => 0, 'low' => 0 }, @capsule.weights)
  end

  # Mixed string + array entries (as a hand-written YAML might combine them).
  def test_queues_setter_accepts_mixed_string_and_array_entries
    @capsule.queues = ['high,3', ['default', 2], 'low,1']

    assert_equal({ 'high' => 3, 'default' => 2, 'low' => 1 }, @capsule.weights)
  end

  def test_queues_setter_raises_on_non_integer_array_weight
    assert_raises(ArgumentError) { @capsule.queues = [%w[high foo]] }
  end

  # A nested array with a stray third element is a config mistake, not a
  # [name, weight] pair — reject it instead of silently truncating to entry[0..1].
  def test_queues_setter_raises_on_oversized_array_entry
    assert_raises(ArgumentError) { @capsule.queues = [['high', 2, 'x']] }
  end

  def test_queues_setter_raises_on_blank_queue_name
    assert_raises(ArgumentError) { @capsule.queues = [''] }
    assert_raises(ArgumentError) { @capsule.queues = ['  '] }
    assert_raises(ArgumentError) { @capsule.queues = [',2'] }
  end

  def test_queues_setter_raises_on_zero_or_negative_explicit_weight
    assert_raises(ArgumentError) { @capsule.queues = ['high,0'] }
    assert_raises(ArgumentError) { @capsule.queues = ['high,-1'] }
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

  # Main pool = concurrency + POOL_HEADROOM once past the MIN_POOL_SIZE floor.
  # Blocking fetch draws from the separate fetch pool, so this pool only serves
  # the background loops + job-code checkouts.
  def test_redis_pool_size_is_concurrency_plus_headroom
    @capsule.concurrency = 7

    assert_equal 7 + Wurk::Capsule::POOL_HEADROOM, @capsule.redis_pool.size
  end

  def test_redis_pool_size_is_floored_at_minimum
    @capsule.concurrency = 1

    assert_equal Wurk::Capsule::MIN_POOL_SIZE, @capsule.redis_pool.size
  end

  # config.redis = { size: N } pins the main pool at N, overriding the formula.
  def test_redis_pool_size_honors_config_size_override
    @config.redis = { size: 42 }
    cap = Wurk::Capsule.new('override', @config)

    assert_equal 42, cap.redis_pool.size
  ensure
    cap&.redis_pool&.disconnect!
  end

  def test_redis_pool_is_memoized
    assert_same @capsule.redis_pool, @capsule.redis_pool
  end

  def test_fetch_redis_pool_size_matches_concurrency
    @capsule.concurrency = 4

    assert_equal 4, @capsule.fetch_redis_pool.size
  end

  def test_redis_pool_and_fetch_pool_are_distinct
    refute_same @capsule.redis_pool, @capsule.fetch_redis_pool
  end

  def test_redis_pool_url_from_config
    @config.redis = { url: 'redis://127.0.0.1:6379/0' }
    cap = Wurk::Capsule.new('x', @config)

    assert_equal 'redis://127.0.0.1:6379/0', cap.redis_pool.url
  ensure
    cap&.redis_pool&.disconnect!
  end

  def test_reset_redis_pools_drops_cached_pools
    pool = @capsule.redis_pool
    fetch = @capsule.fetch_redis_pool

    @capsule.reset_redis_pools!

    refute_same pool, @capsule.redis_pool, 'main pool should be rebuilt after reset'
    refute_same fetch, @capsule.fetch_redis_pool, 'fetch pool should be rebuilt after reset'
  end

  def test_reset_redis_pools_is_safe_when_pools_were_never_built
    cap = Wurk::Capsule.new('untouched', @config)

    cap.reset_redis_pools! # must not raise
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
