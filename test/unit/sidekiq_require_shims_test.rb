# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# E12: every supported `require "sidekiq…"` path the specs document must resolve
# to a Wurk shim once the real sidekiq gems are gone. Each path is required first
# thing in a fresh process under this bundle, which keeps the globally installed
# sidekiq / sidekiq-pro / sidekiq-ent gems off the load path — on a dev box
# with them installed, an in-process require would quietly load the real gem
# and mask a missing shim.
class SidekiqRequireShimsTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  LIB = File.join(ROOT, 'lib')
  SPECS = Dir[File.join(ROOT, 'docs/target/sidekiq-*.md')].freeze
  REQUIRE = %r{require\s*\(?\s*["'](sidekiq[\w\-/]*)["']}

  # Upstream sidekiq 8.1 files apps and gems require directly, each with the
  # constant it defines, or nil for an intentional unsupported exclusion.
  # Upstream files whose constant Wurk does not implement
  # (sidekiq/monitor, paginator, ring_buffer, sd_notify, systemd,
  # metrics/shared, metrics/tracking, job/iterable/enumerators) stay unshimmed:
  # a shim there would turn a clear LoadError into a later NameError.
  UPSTREAM = {
    'sidekiq/capsule' => 'Sidekiq::Capsule',
    'sidekiq/component' => 'Sidekiq::Component',
    'sidekiq/config' => 'Sidekiq::Config',
    'sidekiq/deploy' => 'Sidekiq::Deploy',
    'sidekiq/embedded' => 'Sidekiq::Embedded',
    'sidekiq/fetch' => 'Sidekiq::BasicFetch',
    'sidekiq/iterable_job' => 'Sidekiq::IterableJob',
    'sidekiq/job/interrupt_handler' => 'Sidekiq::Job::InterruptHandler',
    'sidekiq/job/iterable' => 'Sidekiq::Job::Iterable',
    'sidekiq/job/iterable/active_record_enumerator' => 'Sidekiq::Job::Iterable::ActiveRecordEnumerator',
    'sidekiq/job/iterable/csv_enumerator' => 'Sidekiq::Job::Iterable::CsvEnumerator',
    'sidekiq/job_logger' => 'Sidekiq::JobLogger',
    'sidekiq/job_util' => 'Sidekiq::JobUtil',
    'sidekiq/loader' => 'Sidekiq::Loader',
    'sidekiq/logger' => 'Sidekiq::Logger',
    'sidekiq/metrics/query' => 'Sidekiq::Metrics::Query',
    'sidekiq/metrics/tracking' => nil,
    'sidekiq/middleware/modules' => 'Sidekiq::ServerMiddleware',
    'sidekiq/profiler' => 'Sidekiq::Profiler',
    'sidekiq/redis_client_adapter' => 'Sidekiq::RedisClientAdapter',
    'sidekiq/test_api' => 'Sidekiq::Testing',
    'sidekiq/testing/inline' => 'Sidekiq::Testing',
    'sidekiq/transaction_aware_client' => 'Sidekiq::TransactionAwareClient',
    'sidekiq/web/application' => nil,
    'sidekiq/web/router' => nil,
    'sidekiq/web/action' => nil,
    'sidekiq/web/helpers' => nil,
    'sidekiq/worker_compatibility_alias' => 'Sidekiq::Worker'
  }.freeze

  # Keep the probe inventory independent of filesystem discovery: adding a shim
  # must fail completeness until its isolated require probe is registered here.
  OTHER_PATHS = %w[
    sidekiq
    sidekiq-pro
    sidekiq-ent
    sidekiq-ent/periodic/testing
    sidekiq-ent/web
    sidekiq/api
    sidekiq/cli
    sidekiq/client
    sidekiq/job
    sidekiq/job_retry
    sidekiq/launcher
    sidekiq/manager
    sidekiq/middleware/chain
    sidekiq/middleware/current_attributes
    sidekiq/middleware/i18n
    sidekiq/middleware/server/statsd
    sidekiq/pro/web
    sidekiq/processor
    sidekiq/rails
    sidekiq/redis_connection
    sidekiq/scheduled
    sidekiq/testing
    sidekiq/version
    sidekiq/web
    sidekiq/worker
  ].freeze

  UNSUPPORTED = UPSTREAM.select { |_, constant| constant.nil? }.keys.freeze
  SUPPORTED = UPSTREAM.compact.freeze
  DOCUMENTED = SPECS.flat_map { |f| File.read(f).scan(REQUIRE).flatten }.uniq.freeze

  # Only explicit exclusions are removed: unknown newly documented paths must
  # still fail here until they have a shim. Discovery must not register probes.
  PATHS = ((DOCUMENTED + UPSTREAM.keys + OTHER_PATHS).uniq - UNSUPPORTED).sort.freeze

  def self.discover_shim_paths(lib)
    # sidekiq/pro is included recursively under sidekiq.
    patterns = %w[sidekiq/**/*.rb sidekiq-ent/**/*.rb sidekiq.rb sidekiq-pro.rb sidekiq-ent.rb]
    Dir[*patterns.map { |pattern| File.join(lib, pattern) }]
      .map { |file| file.delete_prefix("#{lib}/").delete_suffix('.rb') }.uniq.sort
  end

  SHIM_PATHS = discover_shim_paths(LIB).freeze

  SHIM_PATHS.each do |path|
    define_method(:"test_probe_inventory_covers_lib/#{path}.rb") do
      assert_shims_have_probes([path], PATHS)
    end
  end

  def test_complete_probe_inventory_is_accepted
    assert_shims_have_probes(SHIM_PATHS, PATHS)
  end

  %w[sidekiq/unlisted_shim sidekiq/pro/nested/unlisted_shim sidekiq-ent/nested/unlisted_shim].each do |path|
    define_method(:"test_discovered_unregistered_lib/#{path}.rb_is_rejected") do
      Dir.mktmpdir('sidekiq-shims') do |lib|
        registered = %w[sidekiq sidekiq-pro sidekiq-ent sidekiq/client]
        (registered + [path]).each do |shim|
          file = File.join(lib, "#{shim}.rb")
          FileUtils.mkdir_p(File.dirname(file))
          File.write(file, "# fixture shim\n")
        end

        discovered = self.class.discover_shim_paths(lib)

        assert_equal (registered + [path]).sort, discovered
        error = assert_raises(Minitest::Assertion) do
          assert_shims_have_probes(discovered, registered)
        end

        assert_includes error.message, "lib/#{path}.rb"
      end
    end
  end

  def test_removed_existing_probe_is_rejected
    path = 'sidekiq/client'
    error = assert_raises(Minitest::Assertion) do
      assert_shims_have_probes(SHIM_PATHS, PATHS - [path])
    end

    assert_includes error.message, "lib/#{path}.rb"
  end
  # What each supported path has to leave defined beyond the alias layer itself.
  EXPECTED = SUPPORTED.merge(
    'sidekiq/api' => 'Sidekiq::WorkSet',
    'sidekiq/cli' => 'Sidekiq::CLI',
    'sidekiq/middleware/i18n' => 'Sidekiq::Middleware::I18n::Client',
    'sidekiq/middleware/current_attributes' => 'Sidekiq::CurrentAttributes::Save',
    'sidekiq/middleware/server/statsd' => 'Sidekiq::Middleware::Server::Statsd',
    'sidekiq/pro/web' => 'Sidekiq::Pro::Web',
    'sidekiq/testing' => 'Sidekiq::Testing',
    'sidekiq/web' => 'Sidekiq::Web',
    'sidekiq-ent/web' => 'Sidekiq::Web',
    'sidekiq-ent/periodic/testing' => 'Sidekiq::Periodic::ConfigTester'
  ).freeze

  PROBE = <<~RUBY
    require ARGV[0]
    leaked = $LOADED_FEATURES.grep(%r{/gems/sidekiq(-pro|-ent)?-\\d})
    resolved = Object.const_get(ARGV[1]) rescue nil
    print JSON.dump('leaked' => leaked, 'resolved' => !resolved.nil?, 'wurk' => defined?(Wurk::VERSION) ? true : false)
  RUBY

  def test_the_spec_list_is_not_empty
    assert_includes PATHS, 'sidekiq-ent/periodic/testing'
    assert_includes PATHS, 'sidekiq/middleware/current_attributes'
    assert_operator PATHS.size, :>=, 34
  end

  def test_only_the_five_documented_internals_are_excluded
    assert_equal %w[
      sidekiq/metrics/tracking
      sidekiq/web/action
      sidekiq/web/application
      sidekiq/web/helpers
      sidekiq/web/router
    ], UNSUPPORTED.sort
    assert_empty UNSUPPORTED & PATHS
    assert_empty (DOCUMENTED - UNSUPPORTED) - PATHS
    assert_empty SUPPORTED.keys - PATHS
    refute_includes EXPECTED.values, nil

    ['docs/target/sidekiq-free.md', 'docs/migrate-from-sidekiq.md'].each do |file|
      text = File.read(File.join(ROOT, file))
      UNSUPPORTED.each do |path|
        message = "#{file} must explicitly classify #{path}.rb as unsupported"

        assert_match(/^.*`#{Regexp.escape(path)}\.rb`.*unsupported.*$/, text, message)
      end
      assert_includes text, 'intentionally unshimmed'
      assert_includes text, "require 'sidekiq/web'"
      assert_includes text, "require 'sidekiq/metrics/query'"
    end
  end

  UNSUPPORTED.each do |path|
    define_method(:"test_require_#{path.tr('/-', '__')}_is_intentionally_unshimmed") do
      refute_path_exists File.join(LIB, "#{path}.rb")
      _out, err, status = probe(path, 'Object')

      refute_predicate status, :success?, "#{path} is an unsupported upstream internal"
      assert_match(/LoadError/, err)
      assert_match(/cannot load such file -- #{Regexp.escape(path)}(?:\s|$)/, err)
    end
  end

  def test_the_real_gems_are_off_the_load_path
    _out, err, status = probe('sidekiq-ent/limiter', 'Object')

    refute_predicate status, :success?, 'a path only the real sidekiq-ent gem has must not load'
    assert_match(/LoadError|cannot load such file/, err)
  end

  def test_cold_rails_require_loads_only_the_railtie
    out, err, status = probe_script(<<~RUBY)
      require 'sidekiq/rails'
      print JSON.dump(
        'railtie' => !!defined?(Wurk::Railtie),
        'engine' => !!defined?(Wurk::Engine),
        'action_dispatch' => !!defined?(ActionDispatch)
      )
    RUBY

    assert_predicate status, :success?, err
    result = JSON.parse(out)

    assert result['railtie'], 'sidekiq/rails must define Wurk::Railtie without preloading ActiveJob'
    refute result['engine'], 'sidekiq/rails must not load the dashboard engine'
    refute result['action_dispatch'], 'sidekiq/rails must not load ActionDispatch'
  end

  # Sidekiq 8.1's side-effect-free testing API must not flip the test mode
  # the way the deprecated sidekiq/testing does.
  def test_test_api_leaves_the_test_mode_alone
    _out, err, status = probe_script('require "sidekiq/test_api"; exit(Sidekiq::Testing.disabled? ? 0 : 1)')

    assert_predicate status, :success?, err
  end

  PATHS.each do |path|
    define_method(:"test_require_#{path.tr('/-', '__')}_resolves_to_wurk") do
      out, err, status = probe(path, EXPECTED.fetch(path, 'Sidekiq::Client'))

      assert_predicate status, :success?, "require #{path.inspect} failed:\n#{err}"
      result = JSON.parse(out)

      assert result['wurk'], "#{path} must load Wurk"
      assert result['resolved'], "#{path} must define #{EXPECTED.fetch(path, 'Sidekiq::Client')}"
      assert_empty result['leaked'], "#{path} loaded the real gem"
    end
  end

  private

  def assert_shims_have_probes(shim_paths, probe_paths)
    shim_paths.each do |path|
      assert_includes probe_paths, path, "lib/#{path}.rb must have an isolated require probe"
    end
  end

  def probe(path, constant) = probe_script(PROBE, path, constant)

  def probe_script(script, *)
    env = { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile') }
    Open3.capture3(env, RbConfig.ruby, '-rbundler/setup', *Wurk::Test::SUBPROCESS_COVERAGE,
                   '-rjson', '-I', LIB, '-e', script, *)
  end
end
