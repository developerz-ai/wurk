# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'open3'
require 'rbconfig'

# E12: every `require "sidekiq…"` path the specs document must resolve to a
# Wurk shim once the real sidekiq gems are gone. Each path is required first
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
  # constant it defines. Upstream files whose constant Wurk does not implement
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
    'sidekiq/middleware/modules' => 'Sidekiq::ServerMiddleware',
    'sidekiq/profiler' => 'Sidekiq::Profiler',
    'sidekiq/redis_client_adapter' => 'Sidekiq::RedisClientAdapter',
    'sidekiq/test_api' => 'Sidekiq::Testing',
    'sidekiq/testing/inline' => 'Sidekiq::Testing',
    'sidekiq/transaction_aware_client' => 'Sidekiq::TransactionAwareClient',
    'sidekiq/worker_compatibility_alias' => 'Sidekiq::Worker'
  }.freeze

  # Documented paths, generated from the specs so a newly documented one
  # fails here until it has a shim, plus the upstream files above.
  PATHS = (SPECS.flat_map { |f| File.read(f).scan(REQUIRE).flatten } + UPSTREAM.keys).uniq.sort.freeze

  # What each path has to leave defined beyond the alias layer itself.
  EXPECTED = UPSTREAM.merge(
    'sidekiq/middleware/i18n' => 'Sidekiq::Middleware::I18n::Client',
    'sidekiq/middleware/current_attributes' => 'Sidekiq::CurrentAttributes::Save',
    'sidekiq/middleware/server/statsd' => 'Sidekiq::Middleware::Server::Statsd',
    'sidekiq/pro/web' => 'Sidekiq::Pro::Web',
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

  def test_the_real_gems_are_off_the_load_path
    _out, err, status = probe('sidekiq-ent/limiter', 'Object')

    refute_predicate status, :success?, 'a path only the real sidekiq-ent gem has must not load'
    assert_match(/LoadError|cannot load such file/, err)
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

  def probe(path, constant) = probe_script(PROBE, path, constant)

  def probe_script(script, *)
    env = { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile') }
    Open3.capture3(env, RbConfig.ruby, '-rbundler/setup', *Wurk::Test::SUBPROCESS_COVERAGE,
                   '-rjson', '-I', LIB, '-e', script, *)
  end
end
