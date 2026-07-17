# frozen_string_literal: true

require_relative '../test_helper'
require 'etc'

class ConfigurationTest < Wurk::Test::UnitCase
  parallelize_me!

  ENV_KNOBS = %w[WURK_COUNT SIDEKIQ_COUNT WURK_MAXMEM_MB SIDEKIQ_MAXMEM_MB].freeze

  def setup
    @config = Wurk::Configuration.new
    # default_topology / memory_limit_mb read these; neutralize the ambient env
    # so the tests are deterministic and teardown always restores the originals.
    @saved_env = ENV_KNOBS.to_h { |k| [k, ENV.fetch(k, nil)] }
    ENV_KNOBS.each { |k| ENV.delete(k) }
  end

  def teardown
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
    super
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
    %i[startup fork quiet shutdown exit heartbeat beat].each do |evt|
      assert_kind_of Array, @config[:lifecycle_events][evt], "missing bucket for #{evt}"
    end
  end

  # deep_dup_defaults' Hash branch (configuration.rb:367) dups each inner value
  # only `if inner.respond_to?(:dup)`. The else side is unreachable: it runs
  # solely against the frozen DEFAULTS constant, whose only Hash value is
  # :lifecycle_events (all-Array values, every one of which responds to :dup),
  # and in Ruby >= 3.2 every object responds to :dup anyway. There is no public
  # seam to inject a non-dup-able inner value, so the branch can't be exercised
  # without modifying lib/. Documented here instead of asserting it.
  def test_deep_dup_defaults_else_branch_is_unreachable
    skip 'configuration.rb:367 else is dead code: DEFAULTS has no non-dup-able Hash value'
  end

  def test_init_preserves_supplied_error_handlers
    custom = ->(_ex, _ctx, _cfg) {}
    config = Wurk::Configuration.new(error_handlers: [custom])

    assert_equal [custom], config.error_handlers
    refute_includes config.error_handlers, Wurk::Configuration::ERROR_HANDLER
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

  # --- memory limit (SIDEKIQ_MAXMEM_MB, Ent §7.5) -----------------------

  def test_memory_limit_defaults_to_nil_when_unset
    assert_nil @config.memory_limit_mb
    assert_nil @config.memory_limit_kb
  end

  def test_memory_limit_reads_sidekiq_maxmem_mb_env
    ENV['SIDEKIQ_MAXMEM_MB'] = '1500'

    assert_equal 1500, @config.memory_limit_mb
    assert_equal 1500 * 1024, @config.memory_limit_kb
  end

  def test_memory_limit_prefers_wurk_native_env_over_sidekiq
    ENV['SIDEKIQ_MAXMEM_MB'] = '1500'
    ENV['WURK_MAXMEM_MB'] = '2000'

    assert_equal 2000, @config.memory_limit_mb
  end

  def test_memory_limit_setter_overrides_env
    ENV['SIDEKIQ_MAXMEM_MB'] = '1500'
    @config.memory_limit_mb = 800

    assert_equal 800, @config.memory_limit_mb
    assert_equal 800 * 1024, @config.memory_limit_kb
  end

  def test_memory_limit_kb_disabled_when_zero
    @config.memory_limit_mb = 0

    assert_nil @config.memory_limit_kb, 'zero disables recycling'
  end

  def test_memory_limit_unparseable_env_disables_rather_than_raises
    ENV['SIDEKIQ_MAXMEM_MB'] = 'not-a-number'

    assert_nil @config.memory_limit_mb
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

  def test_server_middleware_yields_chain
    yielded = nil
    @config.server_middleware { |chain| yielded = chain }

    assert_same @config.server_middleware, yielded
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

  def test_redis_config_passes_socket_timeouts_through_to_pool
    @config.redis = { url: Wurk::Test.redis_url, read_timeout: 5.0, reconnect_attempts: 2 }
    pool = @config.new_redis_pool(3, 'passthrough')

    assert_equal({ read_timeout: 5.0, reconnect_attempts: 2 },
                 pool.client_config.slice(:read_timeout, :reconnect_attempts))
  ensure
    pool&.disconnect!
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

  # --- Sidekiq Pro drop-in no-ops ---------------------------------------
  # Reliable fetch + atomic scheduler are already the default, so these toggles
  # do nothing — but a Pro initializer must drop in without NoMethodError.

  def test_super_fetch_bang_is_a_noop
    assert_nil @config.super_fetch!
    assert_nil @config.super_fetch!(timeout: 3)
  end

  def test_super_fetch_callback_nil_by_default
    assert_nil @config.super_fetch_callback
  end

  # Pro's recovery callback: `super_fetch! { |jobstr, pill| }` stores the block
  # (still returning nil) so the reaper can invoke it. Spec: sidekiq-pro.md §3.1.
  def test_super_fetch_bang_stores_the_recovery_block
    block = ->(_jobstr, _pill) {}

    assert_nil @config.super_fetch!(&block)
    assert_same block, @config.super_fetch_callback
  end

  def test_reliable_scheduler_bang_swaps_in_atomic_promoter
    assert_nil @config[:scheduled_enq]

    assert_nil @config.reliable_scheduler!
    assert_equal Wurk::Scheduled::ReliableEnq, @config[:scheduled_enq]
  end

  # Pro super_fetch §3.3: the fetch-poll backoff knob. Unset → nil (the fetcher
  # falls back to its TIMEOUT default); settable via the accessor and readable
  # via the [] options hash.
  def test_fetch_poll_interval_accessor
    assert_nil @config.fetch_poll_interval

    @config.fetch_poll_interval = 0.5

    assert_in_delta 0.5, @config.fetch_poll_interval, 1e-9
    assert_in_delta 0.5, @config[:fetch_poll_interval], 1e-9
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

  def test_default_error_handler_logs_redis_errors_at_warn
    io = StringIO.new
    @config.logger = ::Logger.new(io)
    @config.logger.level = ::Logger::INFO

    Wurk::Configuration::ERROR_HANDLER.call(RedisClient::ConnectionError.new('down'), {}, @config)

    assert_match(/WARN/, io.string)
    assert_match(/down/, io.string)
  end

  def test_default_error_handler_logs_pool_timeouts_at_warn
    io = StringIO.new
    @config.logger = ::Logger.new(io)

    Wurk::Configuration::ERROR_HANDLER.call(ConnectionPool::TimeoutError.new('waited'), {}, @config)

    assert_match(/WARN/, io.string)
  end

  def test_default_error_handler_logs_non_redis_errors_at_info
    io = StringIO.new
    @config.logger = ::Logger.new(io)
    @config.logger.level = ::Logger::INFO

    Wurk::Configuration::ERROR_HANDLER.call(StandardError.new('plain'), {}, @config)

    assert_match(/INFO/, io.string)
    assert_match(/plain/, io.string)
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

  # --- redis-error telemetry (#101) --------------------------------------

  def test_redis_error_handlers_default_empty
    assert_empty @config.redis_error_handlers
  end

  def test_on_redis_error_registers_a_handler
    block = ->(_info) {}
    @config.on_redis_error(&block)

    assert_includes @config.redis_error_handlers, block
  end

  def test_on_redis_error_requires_a_block
    assert_raises(ArgumentError) { @config.on_redis_error }
  end

  def test_redis_error_handlers_not_shared_between_instances
    @config.on_redis_error { :noop }

    assert_empty Wurk::Configuration.new.redis_error_handlers
  end

  def test_dispatch_redis_error_invokes_handlers_with_payload
    seen = []
    @config.on_redis_error { |info| seen << info }
    payload = { error: RuntimeError.new('x'), attempt: 2, retried: false, pool: 'p' }

    @config.send(:dispatch_redis_error, payload)

    assert_equal [payload], seen
  end

  def test_dispatch_redis_error_swallows_and_logs_handler_errors
    io = StringIO.new
    @config.logger = ::Logger.new(io)
    @config.on_redis_error { raise 'handler boom' }

    @config.send(:dispatch_redis_error, { error: 'e', attempt: 1, retried: true, pool: 'p' })

    assert_match(/redis_error_handler raised/, io.string)
    assert_match(/handler boom/, io.string)
  end

  def test_built_pools_are_wired_to_the_redis_error_dispatcher
    @config.redis = { url: Wurk::Test.redis_url }
    pool = @config.new_redis_pool(1, 'wired')

    assert pool.instance_variable_get(:@on_error), 'pool must receive an on_error dispatcher'
  ensure
    pool&.disconnect!
  end

  # --- health_check ------------------------------------------------------

  def test_health_check_stores_options
    @config.health_check(port: 9001, bind: '127.0.0.1', ready_window: 15)

    assert_equal({ port: 9001, bind: '127.0.0.1', ready_window: 15 },
                 @config[:health_check_options])
  end

  def test_health_check_rejects_port_above_range
    assert_raises(ArgumentError) { @config.health_check(port: 70_000) }
  end

  def test_health_check_rejects_negative_port
    assert_raises(ArgumentError) { @config.health_check(port: -1) }
  end

  def test_health_check_rejects_non_positive_ready_window
    assert_raises(ArgumentError) { @config.health_check(port: 9001, ready_window: 0) }
  end

  def test_health_check_rejects_empty_bind
    assert_raises(ArgumentError) { @config.health_check(port: 9001, bind: '') }
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

  # :fork is the Ent §7.4 post-fork hook — must be accepted, not raise.
  def test_on_accepts_fork_event
    block = proc {}
    @config.on(:fork, &block)

    assert_includes @config[:lifecycle_events][:fork], block
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

  def test_topology_defaults_to_one_flat_fork_per_cpu
    @config.queues = %w[critical default]
    @config.concurrency = 7

    slot = @config.topology.slots.first

    assert_equal Etc.nprocessors, @config.topology.total_processes
    assert_equal %w[critical default], slot.queues
    assert_equal 7, slot.concurrency
  end

  def test_topology_count_honors_sidekiq_count
    ENV['SIDEKIQ_COUNT'] = '4'

    assert_equal 4, @config.topology.total_processes
  end

  def test_topology_count_fractional_sidekiq_count_multiplies_cpu
    ENV['SIDEKIQ_COUNT'] = '0.5'

    assert_equal [(0.5 * Etc.nprocessors).round, 1].max, @config.topology.total_processes
  end

  def test_topology_count_wurk_count_takes_precedence_over_sidekiq_count
    ENV['WURK_COUNT'] = '3'
    ENV['SIDEKIQ_COUNT'] = '7'

    assert_equal 3, @config.topology.total_processes
  end

  def test_topology_count_invalid_value_falls_back_to_cpu
    ENV['SIDEKIQ_COUNT'] = 'not-a-number'

    assert_equal Etc.nprocessors, @config.topology.total_processes
  end

  def test_topology_count_is_floored_at_one
    ENV['SIDEKIQ_COUNT'] = '0'

    assert_equal 1, @config.topology.total_processes
  end

  def test_explicit_topology_overrides_sidekiq_count
    ENV['SIDEKIQ_COUNT'] = '8'
    @config.topology = Wurk::Topology.flat(count: 2, queues: ['default'], concurrency: 1)

    assert_equal 2, @config.topology.total_processes
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
