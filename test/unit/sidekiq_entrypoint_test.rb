# frozen_string_literal: true

require_relative '../test_helper'

# #204: `require "sidekiq"` (and the documented `sidekiq/…` sub-paths) must
# load Wurk's alias layer — this is what lets code and third-party gems
# written against Sidekiq run on wurk without touching a single require.
class SidekiqEntrypointTest < Wurk::Test::UnitCase
  parallelize_me!

  # Every passthrough except sidekiq/rails (needs Rails — loading it here
  # would leak `defined?(Rails)` into every other parallel test), sidekiq/cli
  # (flips this process into server mode — same leak problem) and
  # sidekiq/testing (flips the process into :fake, which breaks every test
  # class that later shares this fork). All three are covered by dedicated
  # cold-load subprocess tests — see test/unit/testing_require_test.rb for the
  # sidekiq/testing side effect.
  PASSTHROUGHS = %w[
    sidekiq
    sidekiq/api
    sidekiq/client
    sidekiq/job
    sidekiq/launcher
    sidekiq/middleware/chain
    sidekiq/redis_connection
    sidekiq/scheduled
    sidekiq/version
    sidekiq/web
    sidekiq/worker
  ].freeze

  def test_every_passthrough_requires_cleanly_in_process
    PASSTHROUGHS.each do |path|
      require path

      assert defined?(Sidekiq::Client), "#{path} must leave the alias layer loaded"
    end
  end

  # True cold-start: a fresh process where `require "sidekiq"` is the FIRST
  # require — exactly what an ecosystem gem's test helper does. In-process
  # requires above can't prove this because wurk is already loaded here.
  def test_require_sidekiq_cold_loads_wurk
    lib = File.expand_path('../../lib', __dir__)
    ok = system(
      RbConfig.ruby, '-I', lib, '-e',
      'require "sidekiq"; exit(defined?(Sidekiq::Client) && defined?(Wurk) ? 0 : 1)'
    )

    assert ok, 'a fresh `require "sidekiq"` must load wurk and its alias layer'
  end

  # Sidekiq's contract: `Sidekiq.server?` is "has sidekiq/cli been required".
  # Ecosystem test helpers require it precisely to make `configure_server`
  # blocks run (sidekiq-cron's schedule loader registers :startup hooks there).
  def test_require_sidekiq_cli_enters_server_mode
    lib = File.expand_path('../../lib', __dir__)
    ok = system(
      RbConfig.ruby, '-I', lib, '-e',
      'require "sidekiq"; exit 1 if Sidekiq.server?; ' \
      'require "sidekiq/cli"; ' \
      'fired = false; Sidekiq.configure_server { fired = true }; ' \
      'exit(Sidekiq.server? && fired ? 0 : 1)'
    )

    assert ok, 'requiring sidekiq/cli must flip Sidekiq.server? and unlock configure_server blocks'
  end

  # Railtie-grade like upstream: must load with ONLY rails/railtie present
  # (sidekiq-cron's test helper does exactly this — no ActionDispatch), so it
  # maps to the railtie and must NOT drag in the dashboard engine.
  def test_require_sidekiq_rails_cold_loads_railtie_without_actionpack
    lib = File.expand_path('../../lib', __dir__)
    # Same load set as sidekiq-cron's test helper: active_job brings the
    # ActiveSupport core-exts railtie.rb needs; ActionDispatch stays absent.
    ok = system(
      RbConfig.ruby, '-I', lib, '-e',
      'require "active_job"; require "rails/railtie"; require "sidekiq/rails"; ' \
      'exit(defined?(Wurk::Railtie) && !defined?(Wurk::Engine) && !defined?(ActionDispatch) ? 0 : 1)'
    )

    assert ok, '`require "sidekiq/rails"` must load the railtie with railties alone, engine untouched'
  end
end
