# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'open3'
require 'rbconfig'

# E10: every `Sidekiq::*` class/module constant the specs name must resolve,
# and where Wurk has a same-named counterpart the two must be the same object.
# A missing alias is not a NameError for an ecosystem gem — `class
# Sidekiq::JobSet; prepend ...; end` silently defines a fresh, unused class
# (sidekiq-unique-jobs, whose locks then never release) — so the list is
# generated from the specs rather than hand-kept.
#
# Runs in a fresh process: the opt-in requires (i18n, current attributes,
# ActiveJob) register global middleware this test fork must not inherit.
class SpecConstantsTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  SPECS = Dir[File.join(ROOT, 'docs/target/sidekiq-*.md')].freeze
  CONSTANTS = SPECS.flat_map { |f| File.read(f).scan(/\bSidekiq(?:::[A-Z]\w*)+/) }.uniq.sort.freeze

  # Named in the specs, deliberately not provided. Each needs a reason a
  # reviewer can check; anything else missing fails.
  NOT_PROVIDED = {
    # Upstream's ERB dashboard internals. Wurk's dashboard is a SolidJS SPA over
    # a JSON API; extensions go through Wurk::Web's own registration surface.
    'Sidekiq::Web::Action' => :erb_dashboard,
    'Sidekiq::Web::Route' => :erb_dashboard,
    'Sidekiq::Web::Router' => :erb_dashboard,
    'Sidekiq::WebHelpers' => :erb_dashboard,
    # Upstream's private prepend onto Client; Wurk's Client#raw_push hands off
    # to Testing.dispatch_push instead. Not a public surface.
    'Sidekiq::TestingClient' => :private_upstream_module,
    # Wurk advertises as OSS (`Sidekiq.ent?` is false, sidekiq-free.md §32): a
    # version stamp would tell gems the real Enterprise internals are there.
    'Sidekiq::Enterprise::VERSION' => :advertises_as_oss
  }.freeze

  PROBE = <<~'RUBY'
    require 'sidekiq'
    require 'sidekiq/api'
    require 'sidekiq/middleware/i18n'
    require 'sidekiq/middleware/current_attributes'
    require 'sidekiq-ent/periodic/testing'
    require 'active_job'
    require 'active_job/queue_adapters/wurk_adapter'

    report = ARGV.to_h do |name|
      value = begin
        Object.const_get(name)
      rescue NameError
        next [name, { 'resolved' => false }]
      end
      twin_name = name.sub(/\ASidekiq/, 'Wurk')
      twin = begin
        Object.const_get(twin_name)
      rescue NameError
        nil
      end
      same = !value.is_a?(Module) || !twin.is_a?(Module) || value.equal?(twin)
      [name, { 'resolved' => true, 'same' => same, 'twin' => twin_name }]
    end
    print JSON.dump(report)
  RUBY

  def test_the_spec_list_covers_the_data_api
    %w[Sidekiq::JobSet Sidekiq::SortedSet Sidekiq::DeadSet Sidekiq::Loader].each do |name|
      assert_includes CONSTANTS, name
    end
  end

  def test_every_spec_constant_resolves_to_its_wurk_class
    out, err, status = Open3.capture3(
      { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile') },
      RbConfig.ruby, '-rbundler/setup', '-rjson', '-I', File.join(ROOT, 'lib'), '-e', PROBE,
      *(CONSTANTS - NOT_PROVIDED.keys)
    )

    assert_predicate status, :success?, err
    report = JSON.parse(out)
    missing = report.reject { |_, r| r['resolved'] }.keys
    split = report.select { |_, r| r['resolved'] && !r['same'] }.map { |name, r| "#{name} != #{r['twin']}" }

    assert_empty missing, 'spec constants that do not resolve'
    assert_empty split, 'Sidekiq aliases that are a different object than their Wurk class'
  end

  def test_sidekiq_loader_runs_api_hooks
    ran = []
    Sidekiq.loader.on_load(:api) { ran << :late }

    assert_same Wurk.loader, Sidekiq.loader
    assert_same Wurk::Loader, Sidekiq::Loader
    assert_equal [:late], ran, ':api has already loaded, so a late hook runs at once'
  end

  def test_loader_defers_hooks_until_the_component_loads
    loader = Wurk::Loader.new
    ran = []
    loader.on_load(:thing) { ran << 1 }

    assert_empty ran
    loader.run_load_hooks(:thing)

    assert_equal [1], ran
    loader.run_load_hooks(:thing)

    assert_equal [1], ran, 'hooks run once'
  end

  def test_loader_reports_a_failing_hook_and_runs_the_rest
    loader = Wurk::Loader.new
    ran = []
    reported = []
    handler = ->(ex, ctx, _cfg = nil) { reported << [ex.message, ctx[:hook]] if ctx[:hook] == :boom }
    loader.on_load(:boom) { raise 'hook failed' }
    loader.on_load(:boom) { ran << :second }
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      Wurk.configuration.error_handlers << handler
      loader.run_load_hooks(:boom)
    ensure
      Wurk.configuration.error_handlers.delete(handler)
    end

    assert_equal [:second], ran
    assert_equal [['hook failed', :boom]], reported
  end
end
