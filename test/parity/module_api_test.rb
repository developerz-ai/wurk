# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'logger'
require 'securerandom'
require 'stringio'

# Parity oracle for the top-level `Sidekiq` module, written from
# docs/target/sidekiq-free.md §3 (Module `Sidekiq`) — not from Wurk's
# implementation. Every assertion goes through the `Sidekiq::*` aliases, which
# is the surface a drop-in app actually sees.
#
# Enforced:
# - §3 `Sidekiq::Shutdown` inherits from `Interrupt`.
# - §3 `testing!` takes :fake / :disable / :inline and selects :fake when no
#   mode is given.
# - §3 `load_json` / `dump_json` are `JSON.parse` / `JSON.generate`.
# - §3 `redis_pool` follows the current thread's capsule; `redis` yields a
#   connection.
# - §3 `strict_args!` selects :raise / :warn / false, and a bare call selects
#   :raise.
# - §3 `default_job_options` starts as {"retry" => true, "queue" => "default"}
#   and the setter merges into the existing defaults.
# - §3 `default_configuration` is the Config singleton; `configure_server` and
#   `configure_client` gate on server mode; `configure_embed` returns an
#   Embedded whose concurrency is 2.
# - §3 `logger` is the configuration's logger; `freeze!` locks a
#   configuration; `transactional_push!` selects the transaction-aware client.
#
# Process-global state (the testing mode, the strict-args mode, the default
# job options) is changed under Wurk::Test::GLOBAL_STATE_MUTEX and restored in
# an ensure. The default configuration is never frozen and no option of it is
# changed: every configuration-level assertion runs against a fresh
# `Sidekiq::Config`, and the one module-level call that touches the default
# configuration (`configure_server` in a client-mode process) only defers its
# block — it changes no option and runs nothing.
class ModuleApiParityTest < Wurk::Test::UnitCase
  parallelize_me!

  class ModuleApiParityJob
    include Sidekiq::Job

    def perform(*); end
  end

  def setup
    super
    @token = SecureRandom.hex(6)
    @queue = "module-api-#{@token}"
  end

  # --- §3 exceptions ---------------------------------------------------------

  def test_shutdown_interrupt
    assert_operator Sidekiq::Shutdown, :<, Interrupt, 'Sidekiq::Shutdown must inherit from Interrupt'
    assert_kind_of Interrupt, Sidekiq::Shutdown.new
  end

  # --- §3 testing flags ------------------------------------------------------

  def test_testing_default
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      saved = Sidekiq::Testing.mode
      begin
        Sidekiq.testing!

        assert_predicate Sidekiq::Testing, :fake?, 'testing! without a mode selects fake mode'
        assert_predicate Sidekiq, :testing?, 'fake mode is a testing mode'
      ensure
        Sidekiq.testing!(saved)
      end
    end
  end

  def test_testing_modes
    Sidekiq.testing!(:fake) do
      assert_predicate Sidekiq::Testing, :fake?
      assert_predicate Sidekiq, :testing?
    end

    Sidekiq.testing!(:disable) do
      assert_predicate Sidekiq::Testing, :disabled?
      refute_predicate Sidekiq, :testing?
    end

    Sidekiq.testing!(:inline) { assert_predicate Sidekiq::Testing, :inline? }
  end

  # --- §3 JSON ---------------------------------------------------------------

  def test_load_json
    payload = '{"a":[1,2.5,true,null],"b":{"c":"d"}}'

    assert_equal JSON.parse(payload), Sidekiq.load_json(payload)
    assert_equal({ 'a' => [1, 2.5, true, nil], 'b' => { 'c' => 'd' } }, Sidekiq.load_json(payload))
    assert_raises(JSON::ParserError) { Sidekiq.load_json('{not json') }
  end

  def test_dump_json
    payload = { 'a' => [1, 2.5, true, nil], 'b' => 'x' }

    assert_equal JSON.generate(payload), Sidekiq.dump_json(payload)
    assert_equal '{"a":[1,2.5,true,null],"b":"x"}', Sidekiq.dump_json(payload)

    recursive = []
    recursive << recursive
    assert_raises(JSON::NestingError) { JSON.generate(recursive) }
    assert_raises(JSON::NestingError) { Sidekiq.dump_json(recursive) }
  end

  # --- §3 Redis --------------------------------------------------------------

  def test_capsule_pool
    capsule = Sidekiq::Capsule.new("module-api-#{@token}", Sidekiq.default_configuration)
    Thread.current[:wurk_capsule] = capsule

    assert_same capsule.redis_pool, Sidekiq.redis_pool
  ensure
    Thread.current[:wurk_capsule] = nil
  end

  def test_redis_yield
    pong = Sidekiq.redis { |conn| conn.call('PING') }

    assert_equal 'PONG', pong
  end

  # --- §3 args validation ----------------------------------------------------

  def test_strict_args_mode
    with_strict_args(:raise) do
      assert_raises(ArgumentError) { push_symbol_arg }
    end

    warned = with_strict_args(:warn) { capture_log { push_symbol_arg } }

    assert_includes warned, 'native JSON types', ':warn reports the unsafe argument'

    silent = with_strict_args(false) { capture_log { push_symbol_arg } }

    refute_includes silent, 'native JSON types', 'false disables the argument check'
  end

  def test_strict_args_default
    with_strict_args(:warn) do
      Sidekiq.strict_args!

      assert_equal :raise, Wurk.strict_args_mode, 'strict_args! without a mode selects raise'
      assert_raises(ArgumentError) { push_symbol_arg }
    end
  end

  # --- §3 default job options ------------------------------------------------

  def test_default_job_options
    options = Sidekiq.default_job_options

    assert_same(true, options['retry'], 'the default job options enable retries')
    assert_equal 'default', options['queue'], 'the default job options target the default queue'
  end

  def test_merge_job_options
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      saved = Sidekiq.default_job_options.dup
      begin
        Sidekiq.default_job_options = { 'retry' => 7 }
        merged = Sidekiq.default_job_options

        assert_equal 7, merged['retry'], 'the supplied option replaces the old one'
        assert_equal saved['queue'], merged['queue'], 'unrelated defaults survive the merge'
      ensure
        restore_default_job_options(saved)
      end
    end
  end

  # --- §3 configuration entrypoints ------------------------------------------

  def test_configuration_singleton
    config = Sidekiq.default_configuration

    assert_kind_of Sidekiq::Config, config
    assert_same config, Sidekiq.default_configuration
  end

  def test_configure_server
    # The module entry point gates on the configuration's server flag: in a
    # client-mode process the block does not run.
    module_ran = false
    Sidekiq.configure_server { module_ran = true }

    refute module_ran, 'the server block must not run in a client-mode process'

    # The gate itself opens in server mode (a fresh configuration: the default
    # one is never mutated).
    config = fresh_config
    config.enter_server_mode
    ran = false
    config.configure_server { ran = true }

    assert ran, 'the server block runs once the process is a server'
  end

  def test_configure_client
    yielded = nil
    Sidekiq.configure_client { |config| yielded = config }

    assert_same Sidekiq.default_configuration, yielded, 'the client block runs outside server mode'

    config = fresh_config
    config.enter_server_mode
    ran = false
    config.configure_client { ran = true }

    refute ran, 'the client block must not run in a server-mode process'
  end

  def test_configure_embed_result
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      saved = Wurk.configuration.concurrency
      begin
        embedded = Sidekiq.configure_embed

        assert_kind_of Sidekiq::Embedded, embedded
      ensure
        Wurk.configuration.concurrency = saved
      end
    end
  end

  def test_configure_embed_concurrency
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      saved = Wurk.configuration.concurrency
      begin
        embedded = Sidekiq.configure_embed

        assert_equal 2, embedded.config.concurrency, 'embedded concurrency defaults to two'

        overridden = Sidekiq.configure_embed { |config| config.concurrency = 7 }

        assert_equal 7, overridden.config.concurrency, 'the block may override the default'
      ensure
        Wurk.configuration.concurrency = saved
      end
    end
  end

  # --- §3 server / pro / ent flags --------------------------------------------

  # The upstream promise is a namespace probe ("true if Sidekiq::CLI defined",
  # docs/target/sidekiq-free.md §3). Wurk's `server?` is the runtime worker
  # flag: the same gate that decides whether `configure_server` blocks run.
  # Its observable outcome is what the oracle asserts — false in a client-mode
  # process, true once the process enters server mode — through the public
  # `Sidekiq.server?` alias.
  #
  # The flag is process-global, so it is read and restored under the suite's
  # global-state mutex, and the server-mode entry point is handed a
  # configuration of its own: the default configuration is never mutated.
  def test_server_flag
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      saved = Wurk.instance_variable_get(:@server)
      begin
        Wurk.server = false

        refute_predicate Sidekiq, :server?, 'a client-mode process is not a server'

        Wurk.enter_server_mode(fresh_config)

        assert_predicate Sidekiq, :server?, 'the process is a server once it enters server mode'
      ensure
        Wurk.server = saved
      end
    end
  end

  # Upstream probes the namespace ("true if Sidekiq::Pro defined",
  # docs/target/sidekiq-free.md §3). Wurk defines `Sidekiq::Pro` — Pro's
  # features ship free — and still answers false, so a third-party gem that
  # branches on the flag does not take a paid-only path.
  def test_pro_flag
    assert defined?(Sidekiq::Pro), 'the Sidekiq::Pro namespace exists'
    refute_predicate Sidekiq, :pro?, 'Wurk ships the Pro features free and advertises as OSS'
  end

  # The same deliberate divergence for Enterprise: the namespace exists and the
  # flag is false.
  def test_ent_flag
    assert defined?(Sidekiq::Enterprise), 'the Sidekiq::Enterprise namespace exists'
    refute_predicate Sidekiq, :ent?, 'Wurk ships the Enterprise features free and advertises as OSS'
  end

  # --- §3 logger / freeze / transactional push --------------------------------

  def test_logger
    assert_same Sidekiq.default_configuration.logger, Sidekiq.logger
  end

  def test_freeze_configuration
    assert_respond_to Sidekiq, :freeze!

    config = fresh_config
    config.freeze!

    assert_predicate config, :frozen?
    assert_raises(FrozenError) { config[:concurrency] = 9 }
  end

  def test_transactional_push
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      saved = Sidekiq.default_job_options.dup
      begin
        Sidekiq.transactional_push!

        assert_equal Sidekiq::TransactionAwareClient, Sidekiq.default_job_options['client_class']
      ensure
        restore_default_job_options(saved)
      end
    end
  end

  private

  # A configuration of its own: the default one is never frozen and never
  # mutated by this oracle.
  def fresh_config
    Sidekiq::Config.new.tap { |config| config.logger = ::Logger.new(IO::NULL) }
  end

  def push_symbol_arg
    ModuleApiParityJob.set(queue: @queue).perform_async(:not_json_native)
  end

  def with_strict_args(mode)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      saved = Wurk.strict_args_mode
      begin
        Sidekiq.strict_args!(mode)
        yield
      ensure
        Sidekiq.strict_args!(saved)
      end
    end
  end

  def capture_log
    io = StringIO.new
    saved = Wurk.configuration.logger
    Wurk.configuration.logger = ::Logger.new(io)
    yield
    io.string
  ensure
    Wurk.configuration.logger = saved
  end

  # default_job_options= merges, so it cannot drop a key: restore the exact
  # hash the merge grew.
  def restore_default_job_options(saved)
    live = Wurk.default_job_options
    live.clear
    saved.each { |key, value| live[key] = value }
  end
end
