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

  private

  def run_ruby(code)
    system(RbConfig.ruby, '-I', LIB, '-e', code, out: File::NULL, err: File::NULL)
  end
end
