# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'rake' # `::Rake` for the application doubles below
require 'stringio' # capture the refuse-boot log line

# The Railtie is a thin adapter: it registers the `config.wurk` namespace and
# delegates two boot hooks to Wurk::RailsBoot, which owns the decisions —
#   * entering server mode before config/initializers load (#191), and
#   * forking + supervising the swarm in after_initialize.
# A process that won't run workers (WURK_DISABLED / console / test) is not a
# server and must do neither — otherwise the test suite itself would fork a
# swarm and flip Sidekiq.server? on every engine run. The policy lives in
# RailsBoot (asserted directly below); the config namespace is the Railtie's.
class RailtieTest < Wurk::Test::EngineCase
  def test_skip_boot_is_true_in_test_environment
    assert_predicate ::Rails.env, :test?, 'precondition: engine tests run under the test env'
    assert_predicate Wurk::RailsBoot, :skip_boot?, 'test env must never auto-boot the swarm or enter server mode'
  end

  def test_skip_boot_is_true_when_wurk_disabled
    original = ENV.fetch('WURK_DISABLED', nil)
    ENV['WURK_DISABLED'] = '1'

    assert_predicate Wurk::RailsBoot, :skip_boot?
  ensure
    original.nil? ? ENV.delete('WURK_DISABLED') : (ENV['WURK_DISABLED'] = original)
  end

  # The wurk CLI boots the host app itself and then runs a Launcher in this
  # same process. If the railtie also forked a swarm from after_initialize the
  # result would be two independent workers draining one queue — every job, and
  # every cron tick, run twice. The CLI claims the boot before the app loads.
  def test_skip_boot_is_true_once_the_cli_has_claimed_the_worker_boot
    refute_predicate Wurk, :worker_boot_claimed?, 'precondition: nothing has claimed the boot'

    Wurk.claim_worker_boot!

    assert_predicate Wurk::RailsBoot, :skip_boot?, 'the CLI already runs a worker here; the railtie must stand down'
  ensure
    Wurk.instance_variable_set(:@worker_boot_claimed, false)
  end

  # The claim must NOT live in enter_server_mode: the railtie enters server
  # mode too, and claiming there would make it skip its own boot and leave the
  # app with no workers at all.
  def test_entering_server_mode_does_not_claim_the_worker_boot
    Wurk.enter_server_mode(Wurk::Configuration.new)

    refute_predicate Wurk, :worker_boot_claimed?
  ensure
    Wurk.instance_variable_set(:@worker_boot_claimed, false)
  end

  # `rails console` defines ::Rails::Console before initializers run — a console
  # session is not a server and must never fork the swarm.
  def test_skip_boot_is_true_in_rails_console
    skip '::Rails::Console already defined outside this test' if defined?(::Rails::Console)

    begin
      ::Rails.const_set(:Console, Class.new)

      assert_predicate Wurk::RailsBoot, :skip_boot?, 'console mode must never auto-boot the swarm'
    ensure
      ::Rails.send(:remove_const, :Console) if ::Rails.const_defined?(:Console, false)
    end
  end

  # #247 build-context guard. skip_boot? short-circuits on Rails.env.test? in
  # this suite, so the new logic is asserted through `building?` directly.

  # The default Rails Dockerfile precompiles assets under SECRET_KEY_BASE_DUMMY;
  # that fires after_initialize during `docker build` where there's no Redis,
  # so forking the swarm hangs/fails the build.
  def test_building_is_true_under_dummy_secret_key_base
    with_env('SECRET_KEY_BASE_DUMMY' => '1') do
      assert_predicate Wurk::RailsBoot, :building?, 'asset precompile (SECRET_KEY_BASE_DUMMY) must skip the swarm boot'
    end
  end

  # Any env-loading rake task (assets:precompile, db:prepare, ...) is a one-off,
  # not the server, and must not fork. `rails server` boots via Rails::Command,
  # not Rake, so the real server path keeps booting.
  def test_building_is_true_during_a_rake_task
    with_env('SECRET_KEY_BASE_DUMMY' => nil) do
      with_rake_application(fake_rake(['assets:precompile'])) do
        assert_predicate Wurk::RailsBoot, :building?, 'a running rake task must skip the swarm boot'
      end
    end
  end

  def test_building_is_false_without_dummy_secret_or_rake_task
    with_env('SECRET_KEY_BASE_DUMMY' => nil) do
      with_rake_application(fake_rake([])) do
        refute_predicate Wurk::RailsBoot, :building?, 'a plain server boot must not be treated as a build step'
      end
    end
  end

  # Rake internals must never propagate out of the boot decision.
  def test_building_swallows_rake_errors
    raising = Object.new
    def raising.top_level_tasks = raise('boom')

    with_env('SECRET_KEY_BASE_DUMMY' => nil) do
      with_rake_application(raising) do
        refute_predicate Wurk::RailsBoot, :building?
      end
    end
  end

  # --- preforking web-server guard (Task #11) ---
  #
  # Auto-forking the swarm from a process that itself preforks web workers is
  # the highest-risk boot path (N× oversubscription / entangled supervision).
  # The railtie detects the common three servers and refuses to fork unless the
  # host opts into embedded threads-only mode.

  def test_preforking_web_server_is_false_in_a_plain_boot
    with_env('WEB_CONCURRENCY' => nil) do
      refute_predicate Wurk::RailsBoot, :preforking_web_server?,
                       'a non-clustered boot must keep the swarm-fork path enabled'
    end
  end

  def test_unicorn_is_always_preforking
    with_const(:Unicorn, Module.new) do
      assert_predicate Wurk::RailsBoot, :preforking_web_server?
    end
  end

  def test_passenger_is_always_preforking
    with_const(:PhusionPassenger, Module.new) do
      assert_predicate Wurk::RailsBoot, :preforking_web_server?
    end
  end

  def test_puma_cluster_detected_via_web_concurrency
    with_puma do
      with_env('WEB_CONCURRENCY' => '3') do
        assert_predicate Wurk::RailsBoot, :preforking_web_server?, 'Puma + WEB_CONCURRENCY>0 is cluster mode'
      end
    end
  end

  def test_puma_single_mode_is_not_preforking
    with_puma do
      with_env('WEB_CONCURRENCY' => '0') do
        refute_predicate Wurk::RailsBoot, :puma_cluster?, 'WEB_CONCURRENCY=0 is single (threaded) mode'
      end
    end
  end

  def test_boot_action_forks_when_not_preforking
    with_env('WEB_CONCURRENCY' => nil) do
      assert_equal :fork, Wurk::RailsBoot.boot_action(fake_app(embed: nil))
    end
  end

  def test_boot_action_refuses_under_preforking_without_opt_in
    with_const(:Unicorn, Module.new) do
      assert_equal :refuse, Wurk::RailsBoot.boot_action(fake_app(embed: nil))
    end
  end

  def test_boot_action_embeds_under_preforking_with_opt_in
    with_const(:Unicorn, Module.new) do
      assert_equal :embed, Wurk::RailsBoot.boot_action(fake_app(embed: true))
    end
  end

  def test_embed_in_web_defaults_to_false
    refute Wurk::RailsBoot.embed_in_web?(fake_app(embed: nil))
  end

  def test_embed_in_web_reads_the_host_flag
    assert Wurk::RailsBoot.embed_in_web?(fake_app(embed: true))
  end

  # Hosts write `config.wurk.embed_in_web = true`; the namespace must already
  # exist on the application config or that assignment raises NoMethodError.
  def test_config_wurk_namespace_is_available_to_hosts
    assert_respond_to ::Rails.application.config.wurk, :embed_in_web
  end

  # --- at_exit drain contract ---
  #
  # `boot_swarm` registers its at_exit hook BEFORE the fork, so a boot that
  # raises partway still drains the children it already spawned. The hook then
  # fires on the host's main thread while the supervise thread owns the child
  # table; `stop_swarm` is its body — ask, wait, and take over only when no
  # live supervisor will.

  def test_stop_swarm_leaves_the_drain_to_a_live_supervisor
    swarm = FakeSwarm.new
    supervisor = Thread.new do
      sleep 0.01 until swarm.requests.positive?
      swarm.shutdown
    end

    Wurk::RailsBoot.stop_swarm(swarm, supervisor, 5)

    assert_equal 1, swarm.requests, 'the hook must ask the supervisor to drain'
    assert_equal supervisor, swarm.drains.first, 'the drain must run on the thread that owns the child table'
  ensure
    supervisor&.kill
  end

  # boot raised before the supervise thread existed: nobody else will drain the
  # children it managed to fork.
  def test_stop_swarm_drains_inline_without_a_supervisor
    swarm = FakeSwarm.new

    Wurk::RailsBoot.stop_swarm(swarm, nil, 5)

    assert_equal [Thread.current], swarm.drains
  end

  def test_stop_swarm_drains_inline_when_the_supervisor_died
    swarm = FakeSwarm.new
    supervisor = Thread.new { nil }
    supervisor.join

    Wurk::RailsBoot.stop_swarm(swarm, supervisor, 5)

    assert_equal [Thread.current], swarm.drains
  end

  # A supervisor still alive after the join is wedged mid-drain; draining from
  # here too would walk the child table it is already mutating.
  def test_stop_swarm_never_races_a_wedged_supervisor
    swarm = FakeSwarm.new
    supervisor = Thread.new { sleep }

    Wurk::RailsBoot.stop_swarm(swarm, supervisor, 0.05)

    assert_equal 1, swarm.requests
    assert_empty swarm.drains, 'must never drain alongside a live supervisor'
  ensure
    supervisor&.kill
  end

  # Every forked child inherits the hook, and there `@children` lists that
  # child's siblings — only the process that forked the fleet may act on it.
  def test_stop_swarm_is_a_no_op_off_the_owning_process
    swarm = FakeSwarm.new(owner: false)

    Wurk::RailsBoot.stop_swarm(swarm, nil, 5)

    assert_equal 0, swarm.requests
    assert_empty swarm.drains
  end

  # --- embedded boot contract ---
  #
  # Same shape one layer up from the swarm: the drain hook is registered before
  # `run` — which brings the heartbeat, pollers, managers and health listener up
  # one at a time — so a boot that raises partway still has something to stop
  # what it started. The rescue that keeps the host serving HTTP rolls that
  # partial boot back rather than leaking it for the life of the web process.

  def test_boot_embedded_registers_the_drain_hook_before_run
    hooks = []
    instance = FakeEmbedded.new(hooks)

    with_at_exit(hooks) { boot_embedded_with(instance) }

    assert_equal 1, instance.hooks_at_run, 'the drain hook must be registered before run'
  end

  def test_boot_embedded_returns_the_running_instance
    hooks = []
    instance = FakeEmbedded.new(hooks)

    assert_same instance, with_at_exit(hooks) { boot_embedded_with(instance) }
  end

  def test_boot_embedded_drain_hook_stops_the_instance
    hooks = []
    instance = FakeEmbedded.new(hooks)

    with_at_exit(hooks) { boot_embedded_with(instance) }
    hooks.first.call

    assert_equal 1, instance.stops, 'the at_exit hook must drain the embedded workers'
  end

  def test_boot_embedded_rolls_back_a_run_that_raised
    hooks = []
    instance = FakeEmbedded.new(hooks, boom: 'redis down at boot')

    result = with_at_exit(hooks) { boot_embedded_with(instance) }

    assert_nil result, 'a failed embedded boot must keep the host serving HTTP'
    assert_equal 1, instance.stops, 'a partial boot must not outlive the boot attempt'
  end

  def test_refuse_logs_actionable_guidance
    io = StringIO.new
    with_logger(::Logger.new(io)) { Wurk::RailsBoot.refuse_preforking_boot }

    assert_match(/wurkswarm/, io.string, 'must point the host at the standalone runner')
    assert_match(/embed_in_web/, io.string, 'must mention the embedded opt-in')
    assert_match(/WURK_DISABLED/, io.string, 'must mention the silence switch')
  end

  # Stand-in for the swarm that records which thread ran each drain, so the
  # at_exit contract (never `shutdown` alongside a live supervisor) is
  # assertable without forking a real fleet.
  class FakeSwarm
    attr_reader :requests, :drains

    def initialize(owner: true)
      @owner = owner
      @requests = 0
      @drains = []
    end

    def owner? = @owner

    def request_shutdown = @requests += 1

    def shutdown = @drains << Thread.current
  end

  # Stand-in for Wurk::Embedded: records how many at_exit hooks were already
  # registered when `run` ran (the ordering contract) and how often it was
  # asked to stop.
  class FakeEmbedded
    attr_reader :hooks_at_run, :stops

    def initialize(hooks, boom: nil)
      @hooks = hooks
      @boom = boom
      @stops = 0
    end

    def run
      @hooks_at_run = @hooks.size
      raise @boom if @boom
    end

    def stop = @stops += 1
  end

  private

  # `at_exit` inside boot_embedded resolves against the module, so a singleton
  # method intercepts it — the hook is captured instead of being registered on
  # the test process, where it would fire long after the assertions.
  def with_at_exit(hooks)
    Wurk::RailsBoot.define_singleton_method(:at_exit) { |&blk| hooks << blk }
    yield
  ensure
    Wurk::RailsBoot.singleton_class.send(:remove_method, :at_exit)
  end

  def boot_embedded_with(instance)
    klass = Object.new
    klass.define_singleton_method(:new) { |_config| instance }
    with_logger(::Logger.new(IO::NULL)) { Wurk::RailsBoot.boot_embedded(klass) }
  end

  def fake_app(embed:)
    wurk = ::ActiveSupport::OrderedOptions.new
    wurk.embed_in_web = embed
    config = Struct.new(:wurk).new(wurk)
    Struct.new(:config).new(config)
  end

  # Define a top-level constant for the block, restoring prior state. Tests in
  # this file run serially within one parallel_fork worker (no parallelize_me!),
  # so the global mutation is contained; an already-defined constant is left be.
  def with_const(name, value)
    existed = Object.const_defined?(name, false)
    Object.const_set(name, value) unless existed
    yield
  ensure
    Object.send(:remove_const, name) if !existed && Object.const_defined?(name, false)
  end

  def with_puma(&)
    return yield if defined?(::Puma)

    with_const(:Puma, Module.new, &)
  end

  def with_logger(logger)
    original = Wurk.configuration.logger
    Wurk.configuration.logger = logger
    yield
  ensure
    Wurk.configuration.logger = original
  end

  def fake_rake(tasks)
    Struct.new(:top_level_tasks).new(tasks)
  end

  # Swap Rake's application for a double (save/restore). Avoids a minitest/mock
  # dependency, which isn't loadable under the Ruby 3.4 bundled-gems guard.
  def with_rake_application(app)
    original = ::Rake.application
    ::Rake.application = app
    yield
  ensure
    ::Rake.application = original if original
  end

  def with_env(pairs)
    originals = pairs.transform_values { |_| :__unset__ }
    pairs.each_key { |k| originals[k] = ENV.fetch(k, :__unset__) }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| v == :__unset__ ? ENV.delete(k) : ENV[k] = v }
  end
end
