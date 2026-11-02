# frozen_string_literal: true

require_relative '../engine_test_helper'

# What every job gets from the host's Rails reloader, proven through a real
# Processor and real Redis. Jobs run on their own thread: the test's own thread
# already sits inside an executor (executor_around_test_case).
class RailsReloaderTest < Wurk::Test::EngineCase
  self.use_transactional_tests = false

  class Attrs < ActiveSupport::CurrentAttributes
    attribute :value
  end

  SEEN = Queue.new

  class ProbeJob
    include Wurk::Job

    def perform
      connection = ActiveRecord::Base.connection
      connection.execute('SELECT 1')
      SEEN << { active: Rails.application.executor.active?, query_cache: connection.query_cache_enabled,
                leaked: Attrs.value }
      Attrs.value = 'set by the previous job'
    end
  end

  class BoomJob
    include Wurk::Job

    def perform
      ActiveRecord::Base.connection.execute('SELECT 1')
      raise 'job failure'
    end
  end

  def setup
    super
    SEEN.clear
    @queue = "reloader-#{Process.pid}-#{object_id}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @capsule = Wurk::Capsule.new('test', @config)
    @capsule.queues = [@queue]
    @capsule.fetcher = Wurk::Fetcher::Reliable.new(@capsule)
  end

  def teardown
    @capsule.redis_pool.with { |c| c.call('FLUSHDB') }
    Wurk::Processor::WORK_STATE.clear
  ensure
    super
  end

  def test_a_job_runs_inside_the_executor_with_the_query_cache_on
    seen = run_jobs(ProbeJob, 1).first

    assert seen[:active], 'perform must run inside Rails.application.executor'
    assert seen[:query_cache], 'the executor enables the query cache for the job'
  end

  def test_current_attributes_do_not_leak_to_the_next_job_on_a_thread
    leaked = run_jobs(ProbeJob, 2).map { |seen| seen[:leaked] }

    assert_equal [nil, nil], leaked
  end

  def test_the_connection_is_released_after_a_job
    assert_equal 0, leased_after_job(ProbeJob)
  end

  def test_the_connection_is_released_after_a_failed_job
    assert_equal 0, leased_after_job(BoomJob)
  end

  def test_the_rails_error_reporter_sees_a_failed_job_under_the_sidekiq_source
    sources = []
    subscriber = Class.new do
      define_method(:report) { |_error, source: nil, **| sources << source }
    end.new
    Rails.error.subscribe(subscriber)

    leased_after_job(BoomJob)

    assert_includes sources, Wurk::RailsReloader::SOURCE
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  # --- host replacing the reloader ---------------------------------------

  def test_a_replaced_reloader_is_used_instead_of_the_rails_one
    calls = []
    @config[:reloader] = proc do |&job|
      calls << :replaced
      job.call
    end

    seen = run_jobs(ProbeJob, 1).first

    assert_equal [:replaced], calls
    refute seen[:active], 'the replacement decides; Rails is not wrapped around it'
  end

  def test_nil_opts_out_of_the_rails_reloader
    @config[:reloader] = nil

    refute run_jobs(ProbeJob, 1).first[:active]
  end

  def test_install_keeps_a_reloader_the_host_already_set
    custom = proc { |&job| job.call }
    @config[:reloader] = custom

    Wurk::RailsBoot.install_reloader(Rails.application, @config)

    assert_same custom, @config[:reloader]
  end

  def test_install_replaces_the_default_so_a_host_hook_can_wrap_it
    Wurk::RailsBoot.install_reloader(Rails.application, @config)

    assert_instance_of Wurk::RailsReloader, @config[:reloader]
  end

  # --- Rails 7.0 and serialization ---------------------------------------

  def test_source_is_passed_only_to_a_reloader_that_takes_it
    legacy = Class.new { def self.wrap = yield }
    current = Class.new { def self.wrap(**options) = yield(options) }

    assert_equal(:ran, Wurk::RailsReloader.new(stub_app(legacy)).call { :ran })
    assert_equal({ source: Wurk::RailsReloader::SOURCE }, Wurk::RailsReloader.new(stub_app(current)).call { |o| o })
  end

  def test_install_leaves_a_frozen_configuration_alone
    @config.freeze!

    assert_nil Wurk::RailsBoot.install_reloader(Rails.application, @config)
  end

  def test_the_reloader_serializes_without_walking_the_application
    reloader = Wurk::RailsReloader.new(Rails.application)

    assert_empty reloader.as_json
    assert_equal '{"reloader":{}}', ActiveSupport::JSON.encode(reloader: reloader)
    assert_includes reloader.inspect, Rails.application.class.name
  end

  def test_the_configuration_serializes_with_the_reloader_installed
    Wurk::RailsBoot.install_reloader(Rails.application, @config)

    assert_equal '{}', ActiveSupport::JSON.encode(@config[:reloader])
    assert_kind_of String, @config.to_json
    assert_kind_of Hash, @config.as_json
  end

  # --- boot wiring -------------------------------------------------------

  def test_the_railtie_installed_the_reloader_on_the_shared_configuration
    assert_instance_of Wurk::RailsReloader, Wurk.configuration[:reloader]
  end

  # Host after_initialize hooks, routes and the dev-reload hook all precede it.
  def test_a_railtie_in_the_initializer_list_leaves_the_boot_to_the_finisher
    assert_predicate Wurk::RailsBoot, :boot_scheduled?
  end

  def test_wurk_boot_is_the_last_initializer_to_run
    names = Rails.application.initializers.tsort_each.map(&:name)

    assert_equal :wurk_boot, names.last
    assert_operator names.index(:load_config_initializers), :<, names.index(:wurk_boot)
    assert_operator names.index(:set_clear_dependencies_hook), :<, names.index(:wurk_boot)
    assert_equal 1, names.count(:wurk_boot)
  end

  private

  def stub_app(reloader)
    Struct.new(:reloader).new(reloader)
  end

  # A fresh processor on one thread, one job at a time, so "the next job" really
  # is the next job on that thread.
  def run_jobs(klass, count)
    processor = Wurk::Processor.new(@capsule)
    count.times { push(klass) }
    Thread.new { count.times { processor.process_one } }.join(20)
    Array.new(SEEN.size) { SEEN.pop }
  end

  def leased_after_job(klass)
    processor = Wurk::Processor.new(@capsule)
    push(klass)
    Thread.new do
      processor.process_one
      ActiveRecord::Base.connection_pool.active_connection? ? 1 : 0
    end.value
  end

  def push(klass)
    payload = { 'class' => klass.name, 'args' => [], 'queue' => @queue, 'retry' => false,
                'jid' => SecureRandom.hex(12), 'created_at' => 1 }
    @capsule.redis_pool.with { |c| c.call('LPUSH', "queue:#{@queue}", Wurk.dump_json(payload)) }
  end
end
