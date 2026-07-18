# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'rake' # `::Rake` for the application doubles below
require 'stringio' # capture the refuse-boot log line

# The railtie owns two boot decisions, both gated by Railtie.skip_boot?:
#   * entering server mode before config/initializers load (#191), and
#   * forking + supervising the swarm in after_initialize.
# A process that won't run workers (WURK_DISABLED / console / test) is not a
# server and must do neither — otherwise the test suite itself would fork a
# swarm and flip Sidekiq.server? on every engine run.
class RailtieTest < Wurk::Test::EngineCase
  def test_skip_boot_is_true_in_test_environment
    assert_predicate ::Rails.env, :test?, 'precondition: engine tests run under the test env'
    assert_predicate Wurk::Railtie, :skip_boot?, 'test env must never auto-boot the swarm or enter server mode'
  end

  def test_skip_boot_is_true_when_wurk_disabled
    original = ENV.fetch('WURK_DISABLED', nil)
    ENV['WURK_DISABLED'] = '1'

    assert_predicate Wurk::Railtie, :skip_boot?
  ensure
    original.nil? ? ENV.delete('WURK_DISABLED') : (ENV['WURK_DISABLED'] = original)
  end

  # `rails console` defines ::Rails::Console before initializers run — a console
  # session is not a server and must never fork the swarm.
  def test_skip_boot_is_true_in_rails_console
    skip '::Rails::Console already defined outside this test' if defined?(::Rails::Console)

    begin
      ::Rails.const_set(:Console, Class.new)

      assert_predicate Wurk::Railtie, :skip_boot?, 'console mode must never auto-boot the swarm'
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
      assert_predicate Wurk::Railtie, :building?, 'asset precompile (SECRET_KEY_BASE_DUMMY) must skip the swarm boot'
    end
  end

  # Any env-loading rake task (assets:precompile, db:prepare, ...) is a one-off,
  # not the server, and must not fork. `rails server` boots via Rails::Command,
  # not Rake, so the real server path keeps booting.
  def test_building_is_true_during_a_rake_task
    with_env('SECRET_KEY_BASE_DUMMY' => nil) do
      with_rake_application(fake_rake(['assets:precompile'])) do
        assert_predicate Wurk::Railtie, :building?, 'a running rake task must skip the swarm boot'
      end
    end
  end

  def test_building_is_false_without_dummy_secret_or_rake_task
    with_env('SECRET_KEY_BASE_DUMMY' => nil) do
      with_rake_application(fake_rake([])) do
        refute_predicate Wurk::Railtie, :building?, 'a plain server boot must not be treated as a build step'
      end
    end
  end

  # Rake internals must never propagate out of the boot decision.
  def test_building_swallows_rake_errors
    raising = Object.new
    def raising.top_level_tasks = raise('boom')

    with_env('SECRET_KEY_BASE_DUMMY' => nil) do
      with_rake_application(raising) do
        refute_predicate Wurk::Railtie, :building?
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
      refute_predicate Wurk::Railtie, :preforking_web_server?,
                       'a non-clustered boot must keep the swarm-fork path enabled'
    end
  end

  def test_unicorn_is_always_preforking
    with_const(:Unicorn, Module.new) do
      assert_predicate Wurk::Railtie, :preforking_web_server?
    end
  end

  def test_passenger_is_always_preforking
    with_const(:PhusionPassenger, Module.new) do
      assert_predicate Wurk::Railtie, :preforking_web_server?
    end
  end

  def test_puma_cluster_detected_via_web_concurrency
    with_puma do
      with_env('WEB_CONCURRENCY' => '3') do
        assert_predicate Wurk::Railtie, :preforking_web_server?, 'Puma + WEB_CONCURRENCY>0 is cluster mode'
      end
    end
  end

  def test_puma_single_mode_is_not_preforking
    with_puma do
      with_env('WEB_CONCURRENCY' => '0') do
        refute_predicate Wurk::Railtie, :puma_cluster?, 'WEB_CONCURRENCY=0 is single (threaded) mode'
      end
    end
  end

  def test_boot_action_forks_when_not_preforking
    with_env('WEB_CONCURRENCY' => nil) do
      assert_equal :fork, Wurk::Railtie.boot_action(fake_app(embed: nil))
    end
  end

  def test_boot_action_refuses_under_preforking_without_opt_in
    with_const(:Unicorn, Module.new) do
      assert_equal :refuse, Wurk::Railtie.boot_action(fake_app(embed: nil))
    end
  end

  def test_boot_action_embeds_under_preforking_with_opt_in
    with_const(:Unicorn, Module.new) do
      assert_equal :embed, Wurk::Railtie.boot_action(fake_app(embed: true))
    end
  end

  def test_embed_in_web_defaults_to_false
    refute Wurk::Railtie.embed_in_web?(fake_app(embed: nil))
  end

  def test_embed_in_web_reads_the_host_flag
    assert Wurk::Railtie.embed_in_web?(fake_app(embed: true))
  end

  # Hosts write `config.wurk.embed_in_web = true`; the namespace must already
  # exist on the application config or that assignment raises NoMethodError.
  def test_config_wurk_namespace_is_available_to_hosts
    assert_respond_to ::Rails.application.config.wurk, :embed_in_web
  end

  def test_refuse_logs_actionable_guidance
    io = StringIO.new
    with_logger(::Logger.new(io)) { Wurk::Railtie.refuse_preforking_boot }

    assert_match(/wurkswarm/, io.string, 'must point the host at the standalone runner')
    assert_match(/embed_in_web/, io.string, 'must mention the embedded opt-in')
    assert_match(/WURK_DISABLED/, io.string, 'must mention the silence switch')
  end

  private

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
