# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'rake' # `::Rake` for the application doubles below

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

  private

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
