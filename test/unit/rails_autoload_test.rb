# frozen_string_literal: true

require_relative '../test_helper'

# #246: `gem "wurk"` (the default `require "wurk"`, no explicit `require:`) must
# auto-load the Rails engine when Rails is present, so the `:wurk` / `:sidekiq`
# ActiveJob adapter constant exists by the time ActiveJob resolves it during the
# railtie phase. Stock Sidekiq does this via
# `require "sidekiq/rails" if defined?(Rails::Engine)` in lib/sidekiq.rb.
#
# Cold-start subprocesses keep `defined?(Rails)` from leaking into the rest of
# the parallel suite — the same reason SidekiqEntrypointTest subprocess-tests
# `require "sidekiq/rails"`.
class RailsAutoloadTest < Wurk::Test::UnitCase
  parallelize_me!

  LIB = File.expand_path('../../lib', __dir__)

  def test_require_wurk_under_rails_defines_active_job_adapter
    ok = run_ruby(<<~RUBY)
      require "rails"
      require "rails/engine"
      require "active_job"
      require "wurk"
      adapter = defined?(ActiveJob::QueueAdapters::WurkAdapter)
      engine  = defined?(Wurk::Engine)
      exit(adapter && engine ? 0 : 1)
    RUBY

    assert ok, '`require "wurk"` with Rails present must auto-load the engine and define the :wurk AJ adapter (#246)'
  end

  def test_require_wurk_standalone_stays_rails_free
    ok = run_ruby(<<~RUBY)
      require "wurk"
      # No Rails required: the engine/railtie must NOT load — standalone boot
      # stays Rails-free.
      exit(defined?(Wurk::Engine) || defined?(Wurk::Railtie) ? 1 : 0)
    RUBY

    assert ok, 'standalone `require "wurk"` (no Rails) must not load the engine/railtie'
  end

  # Mirrors how sidekiq-cron's test_helper loads things (rails/engine/railties
  # for the railtie API, NO action_dispatch, then `require "sidekiq"`). The
  # auto-load must skip the engine here — `isolate_namespace Wurk` would crash
  # the require chain looking up ActionDispatch::Routing::RouteSet (#249 CI).
  def test_require_wurk_with_partial_rails_skips_engine
    # Mirrors sidekiq-cron's test/test_helper.rb load order (active_job pulls
    # active_support in so rails/railtie can resolve `delegate_missing_to`, then
    # rails/engine/railties defines Rails::Engine — but action_dispatch is never
    # loaded). The auto-load must skip the engine here: `isolate_namespace Wurk`
    # would crash the require chain looking up ActionDispatch::Routing::RouteSet
    # (#249 CI).
    ok = run_ruby(<<~RUBY)
      require "active_job"
      require "rails/railtie"
      require "rails/engine/railties"
      exit 1 if !defined?(::Rails::Engine)
      exit 1 if  defined?(::ActionDispatch::Routing::RouteSet)
      require "wurk"
      exit(defined?(Wurk::Engine) ? 1 : 0)
    RUBY

    assert ok, 'partial Rails (rails/engine/railties without action_dispatch) must not crash `require "wurk"` (#249)'
  end

  # #282: the standalone runners require "wurk" *before* Rails exists, so the
  # load-time guard above is false and stays false — `wurk` is already in
  # $LOADED_FEATURES by the time Wurk::CLI#boot_rails_application runs, so the
  # host app's own Bundler.require can't re-evaluate it. Wurk::Engine must still
  # resolve once Rails is up, or every app that follows the README and mounts the
  # dashboard dies on boot under `wurk` / `wurkswarm`.
  def test_engine_resolves_when_rails_arrives_after_require_wurk
    ok = run_ruby(<<~RUBY)
      require "wurk"
      exit 1 if defined?(Wurk::Engine)

      # ...what Wurk::CLI#boot_rails_application does next.
      require "rails"
      require "action_controller/railtie"

      exit 1 unless Wurk::Engine < ::Rails::Engine
      # Engine only: the runner owns the swarm, so the railtie (whose
      # after_initialize hook forks one) must not come along for the ride.
      exit(defined?(Wurk::Railtie) ? 1 : 0)
    RUBY

    assert ok, 'Wurk::Engine must resolve on demand once Rails is loaded, even if `require "wurk"` came first (#282)'
  end

  # The same thing end to end: a real Rails app whose config/routes.rb mounts the
  # engine, booted in the order the standalone runners produce. Without the
  # const_missing hook this dies exactly as production did —
  # `config/routes.rb:2:in 'block in <top (required)>': uninitialized constant
  # Wurk::Engine (NameError)`.
  def test_rails_app_mounting_the_engine_boots_in_the_standalone_runner_order
    ok = run_ruby(<<~RUBY)
      require "tmpdir"
      require "fileutils"

      require "wurk"
      exit 1 if defined?(Wurk::Engine)

      require "rails"
      require "action_controller/railtie"

      root = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config.ru"), "")
      File.write(File.join(root, "config/routes.rb"), <<~ROUTES)
        Rails.application.routes.draw do
          mount Wurk::Engine => "/wurk"
        end
      ROUTES
      Dir.chdir(root)

      class HostApp < Rails::Application
        config.load_defaults 7.1
        config.eager_load = false
        config.secret_key_base = "x" * 32
        config.logger = Logger.new(IO::NULL)
      end

      HostApp.initialize!

      mounted = HostApp.routes.routes.map { |r| r.path.spec.to_s }.any? { |p| p.start_with?("/wurk") }
      exit(mounted ? 0 : 1)
    RUBY

    assert ok, '`mount Wurk::Engine` in config/routes.rb must not break app boot under wurk/wurkswarm (#282)'
  end

  private

  def run_ruby(code)
    system(RbConfig.ruby, '-I', LIB, '-e', code, out: File::NULL, err: File::NULL)
  end
end
