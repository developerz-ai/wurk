# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'rbconfig'

class BootChecksTest < Wurk::Test::UnitCase
  parallelize_me!

  class LockedJob
    include Wurk::Job

    sidekiq_options lock: :until_executed
  end

  class UniqueWorker
    include Wurk::Job

    sidekiq_options unique_for: 60
  end

  # The shape an ActiveJob class has once wurk's adapter loaded: the options DSL
  # without Wurk::Worker.
  class UniqueActiveJobShape
    include Wurk::Job::Options

    sidekiq_options unique_until: :start
  end

  class OptedOutWorker
    include Wurk::Job

    sidekiq_options unique_for: false
  end

  Spec = Struct.new(:name, :version, :dependencies)

  def setup
    super
    @out = StringIO.new
    @config = Wurk::Configuration.new
    @config.redis = { url: Wurk::Test.redis_url }
    @config.logger = ::Logger.new(@out)
    @redis = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @redis&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  # The shape of Faker::Travel::Airport, which took the whole check down.
  class ClassWithHostileName
    def self.name(size:, region:) = "#{size}#{region}"
    def self.<(_other) = raise(ArgumentError, 'not this one')
  end

  class HostileJob
    include Wurk::Job

    sidekiq_options lock: :until_executed
    def self.name(required:) = required
  end

  def test_a_class_with_its_own_name_method_does_not_cost_the_check
    listed = Wurk::BootChecks.locked_job_classes

    assert_includes listed, 'BootChecksTest::LockedJob'
    assert_includes listed, 'BootChecksTest::HostileJob'
  end

  def test_logs_the_backend_and_version
    Wurk::BootChecks.run(@config, 'redis_version' => '7.4.0')

    assert_match(/Wurk #{Regexp.escape(Wurk::VERSION)} on redis 7\.4\.0/, @out.string)
  end

  def test_recognises_dragonfly_and_valkey_from_info
    assert_equal %w[dragonfly 1.34.0],
                 Wurk::BootChecks.backend('redis_version' => '7.2', 'dragonfly_version' => 'df-v1.34.0')
    assert_equal %w[valkey 8.0.1], Wurk::BootChecks.backend('redis_version' => '7.2.4', 'valkey_version' => '8.0.1')
  end

  def test_warns_below_a_tested_floor_and_not_at_it
    Wurk::BootChecks.log_backend(@config.logger, 'dragonfly_version' => 'df-v1.34.0')

    refute_match(/older than/, @out.string)
    Wurk::BootChecks.log_backend(@config.logger, 'dragonfly_version' => 'df-v1.10.0')

    assert_match(/dragonfly 1\.10\.0 is older than/, @out.string)
  end

  def test_warns_about_live_non_wurk_processes_and_stays_quiet_about_wurk_ones
    process('wurk:1:n', 'cores' => 8, 'queues' => [])
    Wurk::BootChecks.warn_on_foreign_processes(@config)

    refute_match(/not Wurk/, @out.string)
    process('stock:1:n', 'queues' => [])
    Wurk::BootChecks.warn_on_foreign_processes(@config)

    assert_match(/not Wurk share this Redis: stock:1:n/, @out.string)
  end

  def test_warns_about_jobs_whose_lock_option_does_nothing
    Wurk::BootChecks.warn_on_ignored_locks(@config.logger)

    assert_match(/BootChecksTest::LockedJob/, @out.string)
    assert_includes Wurk::BootChecks.locked_job_classes, 'BootChecksTest::LockedJob'
  end

  # G1: `unique_for:` without `unique!` is a no-op the app never hears about.
  def test_warns_about_jobs_whose_unique_options_do_nothing
    with_unique(false) { Wurk::BootChecks.run(@config, nil) }

    assert_match(/unique jobs are not enabled/, @out.string)
    assert_match(/BootChecksTest::UniqueActiveJobShape, BootChecksTest::UniqueWorker/, @out.string)
    refute_match(/OptedOutWorker/, @out.string)
    assert_match(/Sidekiq::Enterprise\.unique!/, @out.string)
  end

  def test_says_nothing_about_unique_options_once_unique_is_enabled
    with_unique(true) { Wurk::BootChecks.warn_on_ignored_unique(@config.logger) }

    refute_match(/unique jobs are not enabled/, @out.string)
  end

  # Without Redis (`wurk boot-check` with no --redis) the app checks still run.
  def test_without_redis_info_only_the_app_checks_run
    Wurk::BootChecks.run(@config, nil)

    refute_match(/on redis|skipped/, @out.string)
    assert_match(/BootChecksTest::LockedJob/, @out.string)
  end

  # G2: the real sidekiq gem next to Wurk.
  def test_names_the_real_sidekiq_gem_what_pulled_it_in_and_the_shim_line
    Wurk::BootChecks.flag_real_sidekiq_gem(@config.logger, specs: real_sidekiq_bundle, strict: false)

    assert_match(/ERROR.*real sidekiq 7\.3\.0 gem/, @out.string)
    assert_match(/Pulled in by: sidekiq-cron\./, @out.string)
    assert_includes @out.string, "tag: 'v#{Wurk::VERSION}', glob: 'ecosystem/sidekiq-shim/*.gemspec'"
    assert_match(/WURK_STRICT=1/, @out.string)
  end

  def test_strict_mode_refuses_the_real_sidekiq_gem
    error = assert_raises(Wurk::Error) do
      Wurk::BootChecks.flag_real_sidekiq_gem(@config.logger, specs: real_sidekiq_bundle, strict: true)
    end

    assert_match(/real sidekiq 7\.3\.0/, error.message)
  end

  def test_the_shim_gem_and_a_bundle_without_sidekiq_pass
    shim = Spec.new('sidekiq', '8.1.5', [::Gem::Dependency.new('wurk')])
    Wurk::BootChecks.flag_real_sidekiq_gem(@config.logger, specs: { 'sidekiq' => shim }, strict: true)
    Wurk::BootChecks.flag_real_sidekiq_gem(@config.logger, specs: {}, strict: true)

    assert_empty @out.string
  end

  def test_a_bundle_that_cannot_be_read_is_reported_not_raised
    broken = Spec.new('sidekiq', '7.3.0', nil)
    Wurk::BootChecks.flag_real_sidekiq_gem(@config.logger, specs: { 'sidekiq' => broken }, strict: true)

    assert_match(/could not check the bundle/, @out.string)
  end

  # The hook itself: `require "wurk"` with the real gem in the bundle.
  def test_loading_wurk_next_to_the_real_sidekiq_gem_refuses_under_strict
    code = "Gem.loaded_specs['sidekiq'] = Gem::Specification.new { |s| s.name = 'sidekiq'; s.version = '7.3.0' }\n" \
           "require 'wurk'"
    lib = ::File.expand_path('../../lib', __dir__)
    _out, err, status = Open3.capture3({ 'WURK_STRICT' => '1', 'COVERAGE' => nil }, ::RbConfig.ruby, '-I', lib,
                                       '-e', code)

    refute_predicate status, :success?
    assert_match(/real sidekiq 7\.3\.0 gem/, err)
  end

  # G3: one line saying what the process is and how big.
  def test_a_swarm_role_line_describes_every_slot
    @config.topology = Wurk::Topology.new.slot(count: 2, queues: %w[a], concurrency: 3)
                                     .slot(count: 1, queues: %w[b], concurrency: 20)
    Wurk::BootChecks.log_swarm_role(@config, 'wurkswarm parent', ar_pool: 25)

    assert_includes @out.string, 'wurk: wurkswarm parent; 2 processes × 3 threads (redis pool 10, fetch 3) + ' \
                                 '1 process × 20 threads (redis pool 25, fetch 20); AR pool 25'
  end

  def test_a_process_role_line_names_capsules_and_an_explicit_pool_size
    @config.redis = { url: Wurk::Test.redis_url, size: 40 }
    @config.concurrency = 10
    @config.capsule('critical') { |cap| cap.concurrency = 2 }
    Wurk::BootChecks.log_process_role(@config, 'wurk', ar_pool: nil)

    assert_includes @out.string, 'wurk: wurk; capsule default × 10 threads (redis pool 40, fetch 10) + ' \
                                 'capsule critical × 2 threads (redis pool 40, fetch 2)'
    refute_match(/AR pool/, @out.string)
  end

  def test_a_client_only_line_gives_the_reason
    Wurk::BootChecks.log_client_only(@config.logger, 'WURK_DISABLED=1')

    assert_match(/wurk: client only \(WURK_DISABLED=1\); this process enqueues and runs no jobs/, @out.string)
  end

  def test_a_role_line_that_cannot_be_built_never_stops_the_boot
    @config.define_singleton_method(:topology) { raise ArgumentError, 'bad topology' }
    Wurk::BootChecks.log_swarm_role(@config, 'wurkswarm parent', ar_pool: nil)

    assert_match(/role line skipped: ArgumentError: bad topology/, @out.string)
  end

  # G4: every job thread needs an Active Record connection.
  def test_warns_when_the_active_record_pool_is_smaller_than_the_job_threads
    @config.concurrency = 10
    Wurk::BootChecks.log_process_role(@config, 'wurk', ar_pool: 5)

    assert_match(/Active Record pool holds 5 connections but this process runs up to 10 job threads/, @out.string)
    assert_match(%r{`pool:` in config/database\.yml to at least 10}, @out.string)
  end

  def test_a_large_enough_active_record_pool_is_quiet
    @config.topology = Wurk::Topology.flat(count: 4, queues: %w[default], concurrency: 10)
    Wurk::BootChecks.log_swarm_role(@config, 'wurkswarm parent', ar_pool: 10)

    refute_match(/Active Record pool/, @out.string)
  end

  def test_listing_caps_a_long_list
    assert_match(/a0, .* and 5 more\z/, Wurk::BootChecks.listing(Array.new(25) { |i| "a#{i}" }))
  end

  def test_a_failing_check_never_stops_the_boot
    broken = Wurk::Configuration.new
    broken.logger = @config.logger
    broken.redis = { url: 'redis://127.0.0.1:1/0', reconnect_attempts: 0 }

    Wurk::BootChecks.run(broken, 'redis_version' => '7.4.0')

    assert_match(/boot checks skipped/, @out.string)
  ensure
    broken&.reset_redis_pools!
  end

  # The standard Sidekiq shape (both blocks) is quiet; only a server that got
  # client blocks and nothing else hears about it.
  def test_a_server_with_only_client_blocks_is_warned
    @config[:server] = true
    @config.configure_client { nil }

    Wurk::BootChecks.run(@config, nil)

    assert_match(/configure_client blocks were skipped, and no configure_server block ran/, @out.string)
  end

  def test_a_server_with_both_blocks_is_quiet
    @config[:server] = true
    @config.configure_client { nil }
    @config.configure_server { nil }

    Wurk::BootChecks.warn_on_client_config_only(@config)

    refute_match(/WARN/, @out.string)
  end

  def test_a_framework_queue_no_process_listens_to_is_warned
    @config.default_capsule.queues = %w[default]
    process('peer:1', 'queues' => %w[critical])

    with_framework_queues('mailers' => 'mail delivery', 'critical' => 'Active Storage analysis') do
      Wurk::BootChecks.warn_on_unconsumed_framework_queues(@config)
    end

    assert_match(/Rails enqueues to mailers \(mail delivery\), which neither this process nor any live one/,
                 @out.string)
    refute_includes @out.string, 'critical ('
  end

  def test_framework_queues_this_process_listens_to_are_quiet
    @config.default_capsule.queues = %w[default mailers]

    with_framework_queues('mailers' => 'mail delivery') do
      Wurk::BootChecks.warn_on_unconsumed_framework_queues(@config)
    end

    assert_empty @out.string
  end

  def test_framework_queue_sets_are_read_off_the_framework_module
    framework = Struct.new(:queues).new({ analysis: 'storage', purge: nil })

    assert_equal({ 'Active Storage analysis' => 'storage', 'Active Storage purge' => nil },
                 Wurk::BootChecks.framework_queue_set('Active Storage', framework))
    assert_empty Wurk::BootChecks.framework_queue_set('Action Mailbox', false)
  end

  def test_a_declared_topology_is_reported_ignored_by_a_single_process
    Wurk::BootChecks.warn_on_ignored_topology(@config, 'wurk')

    assert_empty @out.string

    @config.topology = Wurk::Topology.flat(count: 2, queues: %w[default], concurrency: 5)
    Wurk::BootChecks.warn_on_ignored_topology(@config, 'wurk')

    assert_match(/config.topology is set, but wurk runs a single process and ignores it/, @out.string)
  end

  private

  def with_framework_queues(queues)
    original = Wurk::BootChecks.method(:framework_queues)
    Wurk::BootChecks.define_singleton_method(:framework_queues) { queues }
    yield
  ensure
    Wurk::BootChecks.define_singleton_method(:framework_queues, original)
  end

  def with_unique(enabled)
    was = Wurk::Unique.enabled?
    Wurk::Unique.instance_variable_set(:@enabled, enabled)
    yield
  ensure
    Wurk::Unique.instance_variable_set(:@enabled, was)
  end

  def real_sidekiq_bundle
    {
      'sidekiq' => Spec.new('sidekiq', '7.3.0', [::Gem::Dependency.new('redis-client')]),
      'sidekiq-cron' => Spec.new('sidekiq-cron', '2.3.1', [::Gem::Dependency.new('sidekiq', '>= 6')]),
      'rails' => Spec.new('rails', '8.1.0', [::Gem::Dependency.new('activejob')])
    }
  end

  def process(identity, info)
    @redis.call('SADD', Wurk::Keys::PROCESSES, identity)
    @redis.call('HSET', identity, 'info', ::JSON.generate(info))
  end
end
