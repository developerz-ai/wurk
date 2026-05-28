# frozen_string_literal: true

require_relative '../test_helper'

class ConfigurationTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    @config = Wurk::Configuration.new
  end

  # --- DEFAULTS ----------------------------------------------------------

  def test_defaults_concurrency_is_five
    assert_equal 5, @config[:concurrency]
  end

  def test_defaults_timeout_is_25
    assert_equal 25, @config[:timeout]
  end

  def test_defaults_on_complex_arguments
    assert_equal :raise, @config[:on_complex_arguments]
  end

  def test_defaults_dead_max_jobs
    assert_equal 10_000, @config[:dead_max_jobs]
  end

  def test_defaults_dead_timeout
    assert_equal 180 * 24 * 60 * 60, @config[:dead_timeout_in_seconds]
  end

  def test_defaults_logged_job_attributes
    assert_equal %w[bid tags], @config[:logged_job_attributes]
  end

  def test_defaults_average_scheduled_poll_interval
    assert_equal 5, @config[:average_scheduled_poll_interval]
  end

  def test_defaults_lifecycle_event_buckets_present
    %i[startup quiet shutdown exit heartbeat beat].each do |evt|
      assert_kind_of Array, @config[:lifecycle_events][evt], "missing bucket for #{evt}"
    end
  end

  def test_defaults_are_not_shared_between_instances
    other = Wurk::Configuration.new
    @config[:labels] << 'foo'

    refute_includes other[:labels], 'foo'
  end

  def test_defaults_lifecycle_buckets_not_shared_between_instances
    other = Wurk::Configuration.new
    @config[:lifecycle_events][:startup] << proc {}

    assert_empty other[:lifecycle_events][:startup]
  end

  # --- Hash-like access --------------------------------------------------

  def test_brackets_set_and_get
    @config[:tag] = 'myapp'

    assert_equal 'myapp', @config[:tag]
  end

  def test_fetch_with_default
    assert_equal 'fallback', @config.fetch(:missing, 'fallback')
  end

  def test_key_predicate
    assert @config.key?(:concurrency)
    refute @config.key?(:bogus)
  end

  def test_merge_bang_writes_through
    @config.merge!(tag: 'x', concurrency: 12)

    assert_equal 'x', @config[:tag]
    assert_equal 12, @config[:concurrency]
  end

  def test_dig_into_nested
    assert_kind_of Array, @config.dig(:lifecycle_events, :startup)
  end

  # --- web ---------------------------------------------------------------

  # Non-mutating: just asserts the delegation target, so it stays safe to run
  # in parallel with classes that mutate the Wurk::Web.config singleton.
  def test_web_delegates_to_web_config_singleton
    assert_same Wurk::Web.config, @config.web
  end

  # --- default capsule shortcuts ----------------------------------------

  def test_concurrency_reads_default_capsule
    @config.default_capsule.concurrency = 9

    assert_equal 9, @config.concurrency
  end

  def test_concurrency_setter_writes_default_capsule
    @config.concurrency = 13

    assert_equal 13, @config.default_capsule.concurrency
  end

  def test_queues_shortcut_round_trips
    @config.queues = %w[high default low]

    assert_equal %w[high default low], @config.queues
    assert_equal :strict, @config.default_capsule.mode
  end

  def test_default_capsule_creates_and_memoizes
    cap1 = @config.default_capsule
    cap2 = @config.default_capsule

    assert_same cap1, cap2
    assert_equal 'default', cap1.name
  end

  def test_default_capsule_yields_block
    yielded = nil
    @config.default_capsule { |c| yielded = c }

    assert_same @config.default_capsule, yielded
  end

  def test_capsule_creates_named_units
    cap = @config.capsule('critical')

    assert_equal 'critical', cap.name
    assert_includes @config.capsules.keys, 'critical'
  end

  def test_capsule_yields_for_configuration
    @config.capsule('high') { |c| c.concurrency = 20 }

    assert_equal 20, @config.capsule('high').concurrency
  end

  def test_total_concurrency_sums_capsules
    @config.default_capsule.concurrency = 5
    @config.capsule('high') { |c| c.concurrency = 7 }
    @config.capsule('low') { |c| c.concurrency = 3 }

    assert_equal 15, @config.total_concurrency
  end

  # --- middleware --------------------------------------------------------

  def test_client_middleware_returns_chain
    assert_kind_of Wurk::Middleware::Chain, @config.client_middleware
  end

  def test_client_middleware_yields_chain
    yielded = nil
    @config.client_middleware { |chain| yielded = chain }

    assert_same @config.client_middleware, yielded
  end

  def test_server_middleware_returns_chain
    assert_kind_of Wurk::Middleware::Chain, @config.server_middleware
  end

  # --- redis -------------------------------------------------------------

  def test_redis_setter_merges_url
    @config.redis = { url: 'redis://example.com:6380/2' }

    assert_equal 'redis://example.com:6380/2', @config.redis_config[:url]
  end

  def test_redis_setter_accepts_string_keys
    @config.redis = { 'url' => 'redis://example.com:6380/2' }

    assert_equal 'redis://example.com:6380/2', @config.redis_config[:url]
  end

  def test_redis_pool_delegates_to_default_capsule
    assert_same @config.default_capsule.redis_pool, @config.redis_pool
  end

  def test_local_redis_pool_is_size_10
    assert_equal 10, @config.local_redis_pool.size
  ensure
    @config.local_redis_pool&.disconnect!
  end

  def test_reset_redis_pools_resets_capsules_and_local_pool
    cap_pool = @config.default_capsule.redis_pool
    local_pool = @config.local_redis_pool

    @config.reset_redis_pools!

    refute_same cap_pool, @config.default_capsule.redis_pool
    refute_same local_pool, @config.local_redis_pool
  ensure
    @config.reset_redis_pools!
  end

  def test_reset_redis_pools_calls_through_to_every_capsule
    extra = @config.capsule('extra') { |c| c.concurrency = 1 }
    main_pool = @config.default_capsule.redis_pool
    extra_pool = extra.redis_pool

    @config.reset_redis_pools!

    refute_same main_pool, @config.default_capsule.redis_pool
    refute_same extra_pool, extra.redis_pool
  ensure
    @config.reset_redis_pools!
  end

  # --- service locator ---------------------------------------------------

  def test_register_and_lookup
    obj = Object.new
    @config.register(:thing, obj)

    assert_same obj, @config.lookup(:thing)
  end

  def test_lookup_returns_nil_when_missing
    assert_nil @config.lookup(:nope)
  end

  def test_lookup_creates_with_default_class
    instance = @config.lookup(:auto, Hash)

    assert_kind_of Hash, instance
    assert_same instance, @config.lookup(:auto)
  end

  # --- handlers ----------------------------------------------------------

  def test_error_handlers_default_includes_default_handler
    assert_includes @config.error_handlers, Wurk::Configuration::ERROR_HANDLER
    assert_equal 1, @config.error_handlers.size
  end

  def test_error_handlers_default_not_shared_between_instances
    @config.error_handlers << ->(_ex, _ctx, _cfg) {}
    other = Wurk::Configuration.new

    assert_equal 1, other.error_handlers.size
  end

  def test_error_handlers_appends
    handler = ->(_ex, _ctx, _cfg) {}
    @config.error_handlers << handler

    assert_includes @config.error_handlers, handler
  end

  def test_default_error_handler_logs_full_message_in_debug
    io = StringIO.new
    @config.logger = ::Logger.new(io)
    @config.logger.level = ::Logger::DEBUG
    ex = build_exception('kaboom')

    Wurk::Configuration::ERROR_HANDLER.call(ex, {}, @config)

    assert_match(/kaboom/, io.string)
    assert_match(/backtrace_marker/, io.string)
  end

  def test_default_error_handler_uses_detailed_message_in_prod
    io = StringIO.new
    @config.logger = ::Logger.new(io)
    @config.logger.level = ::Logger::INFO
    ex = build_exception('kaboom')

    Wurk::Configuration::ERROR_HANDLER.call(ex, {}, @config)

    assert_match(/kaboom/, io.string)
    refute_match(/backtrace_marker/, io.string)
  end

  def test_default_error_handler_wraps_ctx_in_wurk_context
    seen = nil
    capturing = Class.new(::Logger) do
      def initialize(callback)
        @callback = callback
        super(IO::NULL)
      end

      def info(*, &blk) = @callback.call(blk&.call)
    end.new(->(*) { seen = Wurk::Context.current.dup })
    @config.logger = capturing

    Wurk::Configuration::ERROR_HANDLER.call(StandardError.new('x'), { jid: 'abc' }, @config)

    assert_equal({ jid: 'abc' }, seen)
  end

  def test_death_handlers_appends
    handler = ->(_job, _ex) {}
    @config.death_handlers << handler

    assert_includes @config.death_handlers, handler
  end

  # --- lifecycle hooks ---------------------------------------------------

  def test_on_appends_to_lifecycle_bucket
    block = proc {}
    @config.on(:startup, &block)

    assert_includes @config[:lifecycle_events][:startup], block
  end

  def test_on_rejects_unknown_event
    assert_raises(ArgumentError) { @config.on(:bogus) { :noop } }
  end

  def test_on_requires_block
    assert_raises(ArgumentError) { @config.on(:startup) }
  end

  # --- logger ------------------------------------------------------------

  def test_logger_defaults_to_logger_instance
    assert_kind_of ::Logger, @config.logger
  end

  def test_logger_setter_overrides
    custom = ::Logger.new(IO::NULL)
    @config.logger = custom

    assert_same custom, @config.logger
  end

  # --- handle_exception --------------------------------------------------

  def test_handle_exception_falls_back_to_logger_when_no_handlers
    io = StringIO.new
    @config.logger = ::Logger.new(io)
    @config.error_handlers.clear
    @config.handle_exception(StandardError.new('boom'), { jid: '1' })

    assert_match(/boom/, io.string)
  end

  def test_handle_exception_default_handler_logs_via_logger
    io = StringIO.new
    @config.logger = ::Logger.new(io)
    @config.handle_exception(StandardError.new('boom'), {})

    assert_match(/boom/, io.string)
  end

  def test_handle_exception_dispatches_to_handlers
    @config.logger = ::Logger.new(IO::NULL)
    seen = []
    @config.error_handlers << ->(ex, ctx, cfg) { seen << [ex.message, ctx, cfg] }
    ex = StandardError.new('hi')

    @config.handle_exception(ex, { jid: 'abc' })

    assert_equal [['hi', { jid: 'abc' }, @config]], seen
  end

  def test_handle_exception_swallows_handler_errors
    io = StringIO.new
    @config.logger = ::Logger.new(io)
    @config.error_handlers << ->(_ex, _ctx, _cfg) { raise 'handler boom' }
    @config.handle_exception(StandardError.new('boom'))

    assert_match(/handler boom/, io.string)
  end

  # --- configure_server / configure_client ------------------------------

  def test_configure_server_yields_when_server_flag_true
    @config[:server] = true
    yielded = nil
    @config.configure_server { |c| yielded = c }

    assert_same @config, yielded
  end

  def test_configure_server_skips_when_not_server
    yielded = false
    @config.configure_server { yielded = true }

    refute yielded
  end

  def test_configure_client_yields_when_not_server
    yielded = nil
    @config.configure_client { |c| yielded = c }

    assert_same @config, yielded
  end

  def test_configure_client_skips_when_server
    @config[:server] = true
    yielded = false
    @config.configure_client { yielded = true }

    refute yielded
  end

  # --- freeze! -----------------------------------------------------------

  def test_freeze_locks_options
    @config.freeze!

    assert_raises(FrozenError) { @config[:concurrency] = 99 }
  end

  def test_freeze_is_idempotent
    @config.freeze!
    @config.freeze!

    assert_predicate @config, :frozen?
  end

  def test_freeze_returns_self
    assert_same @config, @config.freeze!
  end

  # --- topology (regression #36) -----------------------------------------

  def test_topology_returns_a_topology
    assert_instance_of Wurk::Topology, @config.topology
  end

  def test_topology_defaults_to_one_flat_fork_from_default_capsule
    @config.queues = %w[critical default]
    @config.concurrency = 7

    slot = @config.topology.slots.first

    assert_equal 1, @config.topology.total_processes
    assert_equal %w[critical default], slot.queues
    assert_equal 7, slot.concurrency
  end

  def test_topology_default_preserves_weighted_queue_specs
    @config.queues = %w[high,3 default,2]

    assert_equal %w[high,3 default,2], @config.topology.slots.first.queues
  end

  def test_topology_respects_a_custom_assignment
    custom = Wurk::Topology.flat(count: 3, queues: ['bulk'], concurrency: 2)
    @config.topology = custom

    assert_same custom, @config.topology
  end

  def test_topology_setter_raises_once_frozen
    @config.freeze!

    assert_raises(FrozenError) { @config.topology = Wurk::Topology.new }
  end

  private

  def build_exception(message)
    raise StandardError, message
  rescue StandardError => e
    # Force a backtrace_marker entry so we can tell full_message (with bt)
    # apart from detailed_message (no bt) without depending on tempfile names.
    e.set_backtrace(['backtrace_marker:1:in `boom\''])
    e
  end
end
