# frozen_string_literal: true

require_relative '../test_helper'
require 'active_support'
require 'active_support/core_ext/numeric/time'
require 'active_support/core_ext/time/zones'
require 'active_support/testing/time_helpers'
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'

# The surface published Sidekiq add-on gems reach into, each case shaped like
# the gem code that depends on it. Subclasses stand in for the gems' prepends
# and reopened classes, because a real prepend onto Wurk::JobSet would leak into
# every other test in this worker.
class ThirdPartyGemContractTest < Wurk::Test::UnitCase
  include ActiveSupport::Testing::TimeHelpers

  parallelize_me!

  class CapturingJob
    include Wurk::Job

    class << self
      attr_accessor :pushed

      def client_push(item)
        self.pushed = item
        'jid'
      end
    end
  end

  class FakeJob
    include Wurk::Job

    def perform(*); end
  end

  class OtherFakeJob
    include Wurk::Job

    def perform(*); end
  end

  class LegacyWorker
    include Sidekiq::Worker

    def perform(*); end
  end

  class ModernJob
    include Sidekiq::Job

    def perform(*); end
  end

  class NativeWorker
    include Wurk::Worker

    def perform(*); end
  end

  class NestedOptionsJob
    include Wurk::Job

    sidekiq_options lock: :while_executing, on_conflict: { client: :log, server: :reject }
  end

  class CollapsedJob
    include Wurk::Job

    sidekiq_options collapse: { policy: :debounce, wait: 5, max_wait: 60 }
  end

  # sidekiq-unique-jobs: `delete_by_value` answers whether a lock was released,
  # not whether the member was removed, so it is false for any job without one.
  class LockReleasingSet < Wurk::RetrySet
    def delete_by_value(name, value)
      super
      false
    end
  end

  # sidekiq-unique-jobs: wraps the private `remove_job`, parsing what it yields.
  class MessageParsingEntry < Wurk::SortedEntry
    attr_reader :parsed

    private

    def remove_job
      super do |message|
        @parsed = Wurk.load_json(message)
        yield message
      end
    end
  end

  # sidekiq-failures: reopens #initialize and reads @item straight after super.
  class ItemReadingEntry < Wurk::SortedEntry
    def initialize(parent, score, item)
      super
      @item.merge!(@item['payload']) if @item['payload']
    end
  end

  class ConfigReadingMiddleware
    include Wurk::Middleware::ServerMiddleware

    def call(*) = yield
  end

  def setup
    super
    @ns = "#{Process.pid}-#{object_id}"
    @set_name = "retry-#{@ns}"
    @queue = "q-#{@ns}"
    @dead = []
  end

  def teardown
    travel_back
    Wurk.redis do |c|
      c.call('UNLINK', @set_name, "queue:#{@queue}")
      c.call('SREM', 'queues', @queue)
      c.call('ZREM', 'dead', *@dead) unless @dead.empty?
    end
    Wurk::Queues.clear_all
  ensure
    super
  end

  # --- intervals ----------------------------------------------------------

  def test_perform_in_accepts_a_duration
    now = Time.now.to_f
    CapturingJob.perform_in(5.minutes, 1)

    assert_in_delta now + 300, CapturingJob.pushed['at'], 5
  end

  def test_perform_at_accepts_a_duration_as_an_interval
    now = Time.now.to_f
    CapturingJob.perform_at(1.hour, 1)

    assert_in_delta now + 3600, CapturingJob.pushed['at'], 5
  end

  def test_set_wait_accepts_a_duration
    now = Time.now.to_f
    CapturingJob.set(wait: 90.seconds).perform_async(1)

    assert_in_delta now + 90, CapturingJob.pushed['at'], 5
  end

  def test_perform_at_accepts_a_time_with_zone
    target = Time.use_zone('UTC') { 2.hours.from_now }
    CapturingJob.perform_at(target, 1)

    assert_in_delta target.to_f, CapturingJob.pushed['at'], 0.001
  end

  def test_perform_in_still_refuses_a_string
    assert_raises(ArgumentError) { CapturingJob.perform_in('5 minutes', 1) }
  end

  def test_perform_in_is_measured_from_frozen_time
    frozen = Time.utc(2024, 3, 10, 12)
    travel_to(frozen) { CapturingJob.perform_in(300, 1) }

    assert_in_delta frozen.to_f + 300, CapturingJob.pushed['at'], 0.001
  end

  def test_set_wait_is_measured_from_frozen_time
    frozen = Time.utc(2024, 3, 10, 12)
    travel_to(frozen) { CapturingJob.set(wait: 60).perform_async(1) }

    assert_in_delta frozen.to_f + 60, CapturingJob.pushed['at'], 0.001
  end

  # --- Config ------------------------------------------------------------

  def test_redis_info_reports_the_server_version
    assert_match(/\A\d+\.\d+/, Wurk.default_configuration.redis_info['redis_version'])
    assert_same Wurk.default_configuration.method(:redis_info).owner, Sidekiq::Config
  end

  def test_config_to_json_is_a_json_object_of_its_options
    config = Wurk::Configuration.new
    config[:contract_marker] = 'x'

    assert_equal 'x', JSON.parse(config.to_json)['contract_marker']
  end

  def test_top_level_server_chain_binds_its_config
    config = Wurk::Configuration.new
    config.server_middleware.add(ConfigReadingMiddleware)

    assert_same config, config.server_middleware.retrieve.last.config
  end

  def test_top_level_client_chain_binds_its_config
    config = Wurk::Configuration.new
    config.client_middleware.add(ConfigReadingMiddleware)

    assert_same config, config.client_middleware.retrieve.last.config
  end

  # A nil config made Metrics::History raise from perform_inline, and the
  # raise reached every error handler as if the job had failed.
  def test_perform_inline_reports_nothing_to_the_error_handlers
    seen = []
    handler = ->(ex, *) { seen << ex }
    Wurk.configuration.error_handlers << handler

    FakeJob.perform_inline(1)

    assert_empty seen
  ensure
    Wurk.configuration.error_handlers.delete(handler)
  end

  # --- SortedEntry mutations ---------------------------------------------

  def test_retry_pushes_when_delete_by_value_answers_false
    set = LockReleasingSet.new(@set_name)
    seed(set)

    set.first.retry

    assert_equal 0, set.size
    assert_equal 1, Wurk::Queue.new(@queue).size
  end

  def test_kill_moves_to_dead_when_delete_by_value_answers_false
    set = LockReleasingSet.new(@set_name)
    jid = seed(set)

    set.first.kill

    assert_equal 0, set.size
    assert_equal jid, Wurk::DeadSet.new.find_job(jid)&.jid
  end

  def test_add_to_queue_pushes_when_delete_by_value_answers_false
    set = LockReleasingSet.new(@set_name)
    seed(set)

    set.first.add_to_queue

    assert_equal 1, Wurk::Queue.new(@queue).size
  end

  def test_retry_all_pushes_every_job_when_delete_by_value_answers_false
    set = LockReleasingSet.new(@set_name)
    2.times { seed(set) }

    assert_equal 2, set.retry_all
    assert_equal 2, Wurk::Queue.new(@queue).size
  end

  def test_kill_all_moves_every_job_when_delete_by_value_answers_false
    set = LockReleasingSet.new(@set_name)
    jids = Array.new(2) { seed(set) }

    assert_equal 2, set.kill_all

    jids.each { |jid| assert_equal jid, Wurk::DeadSet.new.find_job(jid)&.jid }
  end

  def test_remove_job_yields_the_raw_json_string
    set = Wurk::RetrySet.new(@set_name)
    seed(set)
    raw = set.first.value
    yielded = nil

    set.first.send(:remove_job) { |message| yielded = message }

    assert_equal raw, yielded
  end

  def test_a_wrapper_that_parses_the_yielded_message_can_retry
    set = Wurk::RetrySet.new(@set_name)
    jid = seed(set)
    row, score = Wurk.redis { |c| c.call('ZRANGE', @set_name, 0, 0, 'WITHSCORES').first }
    entry = MessageParsingEntry.new(set, score, row)

    entry.retry

    assert_equal jid, entry.parsed['jid']
    assert_equal 1, Wurk::Queue.new(@queue).size
  end

  def test_retry_decrements_retry_count_on_the_pushed_payload
    set = Wurk::RetrySet.new(@set_name)
    seed(set, 'retry_count' => 4)

    set.first.retry

    assert_equal 3, Wurk::Queue.new(@queue).first['retry_count']
  end

  def test_a_push_that_raises_restores_the_entry
    set = Wurk::RetrySet.new(@set_name)
    seed(set)
    raw = set.first.value
    entry = set.first

    assert_raises(RuntimeError) { entry.send(:remove_job) { raise 'push refused' } }

    assert_equal raw, set.first.value
  end

  def test_kill_stores_the_original_bytes
    set = Wurk::RetrySet.new(@set_name)
    jid = seed(set)
    raw = set.first.value

    set.first.kill

    assert_equal raw, Wurk::DeadSet.new.find_job(jid).value
  end

  # --- SortedEntry construction ------------------------------------------

  def test_item_is_parsed_by_the_time_a_reopened_initialize_reads_it
    json = JSON.generate('class' => 'X', 'jid' => 'j', 'payload' => { 'merged' => 1 })

    assert_equal 1, ItemReadingEntry.new(nil, 1.0, json)['merged']
  end

  def test_corrupt_payload_still_constructs
    entry = ItemReadingEntry.new(nil, 1.0, 'not json')

    assert_equal ['not json'], entry.args
  end

  def test_entry_built_without_a_payload_still_constructs
    assert_in_delta 1.0, Wurk::SortedEntry.new(nil, 1.0, nil).score
  end

  # --- Sidekiq::Worker / Sidekiq::Job ------------------------------------

  def test_worker_and_job_are_one_module
    assert_same Sidekiq::Job, Sidekiq::Worker
  end

  def test_a_class_including_worker_is_a_job
    assert_kind_of Sidekiq::Job, LegacyWorker.new
    assert_operator LegacyWorker, :<, Sidekiq::Job
  end

  def test_a_class_including_job_is_a_worker
    assert_kind_of Sidekiq::Worker, ModernJob.new
  end

  def test_a_class_including_the_native_module_is_a_job
    assert_kind_of Sidekiq::Job, NativeWorker.new
    assert_kind_of Wurk::Worker, NativeWorker.new
  end

  def test_worker_and_job_carry_the_job_methods_themselves
    assert Sidekiq::Worker.method_defined?(:logger)
    assert_same Sidekiq::Worker, Sidekiq::Job.instance_method(:logger).owner
    assert_equal Wurk::Worker::SCHEDULED_THRESHOLD, Sidekiq::Job::SCHEDULED_THRESHOLD
    assert_equal Wurk::Worker::SCHEDULED_THRESHOLD, Sidekiq::Worker::SCHEDULED_THRESHOLD
  end

  # A prepend onto the shared module would leak into this worker, hence the fork.
  def test_a_prepend_on_worker_overrides_job_methods
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      Sidekiq::Worker.prepend(Module.new { def logger = :prepended })
      writer.write(Class.new { include Sidekiq::Job }.new.logger)
      exit!(0)
    end
    writer.close
    Process.wait(pid)

    assert_equal 'prepended', reader.read
  end

  def test_extending_class_methods_before_including_still_defines_the_instance_accessors
    klass = Class.new do
      extend Sidekiq::Job::ClassMethods
      include Sidekiq::Job
    end

    assert klass.method_defined?(:jid=)
  end

  def test_job_exposes_class_methods
    assert_same Wurk::Worker::ClassMethods, Sidekiq::Job::ClassMethods
    assert_same Sidekiq::Job::Options, Sidekiq::Worker::Options
  end

  # --- sidekiq_options ---------------------------------------------------

  def test_sidekiq_options_stringifies_two_levels_of_keys
    assert_equal({ 'client' => :log, 'server' => :reject }, NestedOptionsJob.get_sidekiq_options['on_conflict'])
  end

  def test_a_collapse_policy_survives_stringified_keys
    assert_equal :debounce, Wurk::Collapse.policy_for(CollapsedJob.get_sidekiq_options).name
  end

  def test_sidekiq_options_hash_can_be_assigned
    klass = Class.new { include Sidekiq::Job }
    klass.sidekiq_options_hash = { 'queue' => 'swapped' }

    assert_equal 'swapped', klass.get_sidekiq_options['queue']
    assert_equal 'swapped', klass.sidekiq_options_hash['queue']
  end

  # --- non-object payloads ------------------------------------------------

  ['[1,2]', '123', 'null', '"str"', 'not-json'].each do |payload|
    slug = payload.gsub(/\W/, '_')

    define_method("test_kill_all_moves_a_#{slug}_member_to_dead") { assert_kill_all_moves(payload) }
    define_method("test_retry_all_survives_a_#{slug}_member") { assert_retry_all_survives(payload) }

    define_method("test_a_#{slug}_member_reads_as_an_empty_job") do
      entry = Wurk::SortedEntry.new(nil, 1.0, payload)

      assert_nil entry.jid
      assert_equal [payload], entry.args
    end
  end

  def assert_kill_all_moves(payload)
    set = Wurk::RetrySet.new(@set_name)
    Wurk.redis { |c| c.call('ZADD', @set_name, 1, payload) }
    @dead << payload

    assert_equal 1, set.kill_all
    assert_equal 0, set.size
    assert_includes Wurk.redis { |c| c.call('ZRANGE', 'dead', 0, -1) }, payload
  end

  def assert_retry_all_survives(payload)
    set = Wurk::RetrySet.new(@set_name)
    Wurk.redis { |c| c.call('ZADD', @set_name, 1, payload) }
    seed(set)
    handled = []
    handler = ->(ex, *) { handled << ex }
    Wurk.configuration.error_handlers << handler

    assert_equal 1, set.retry_all
    assert_equal 1, Wurk::Queue.new(@queue).size
    assert_equal 1, set.size, 'the unusable member stays where it was'
    assert_equal 1, handled.size
  ensure
    Wurk.configuration.error_handlers.delete(handler)
  end

  def test_invalid_bytes_read_as_an_empty_job
    entry = Wurk::SortedEntry.new(nil, 1.0, "\xFF\xFE".b)

    assert_nil entry.jid
  end

  # --- server mode ---------------------------------------------------------

  def test_configure_server_block_runs_when_server_mode_is_entered_later
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    ran = []
    config.configure_server { |c| ran << c }

    assert_empty ran

    Wurk.enter_server_mode(config)

    assert_equal [config], ran
  ensure
    Wurk.server = false
  end

  def test_a_deferred_block_runs_once
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    ran = 0
    config.configure_server { ran += 1 }

    2.times { Wurk.enter_server_mode(config) }

    assert_equal 1, ran
  ensure
    Wurk.server = false
  end

  def test_a_block_registered_in_server_mode_still_runs_at_once
    config = Wurk::Configuration.new
    config.enter_server_mode
    ran = false
    config.configure_server { ran = true }

    assert ran
  end

  # --- a forked swarm child ------------------------------------------------

  def test_a_forked_child_can_write_options_until_the_launcher_freezes
    config = Wurk::Configuration.new
    config.prepare_for_fork!

    assert_raises(FrozenError) { config[:cron_poll_interval] = 1 }

    config.reopen_in_forked_child
    config[:cron_poll_interval] = 1

    assert_equal 1, config[:cron_poll_interval]

    config.freeze!

    assert_raises(FrozenError) { config[:cron_poll_interval] = 2 }
  end

  # --- Sidekiq::Rails ------------------------------------------------------

  def test_sidekiq_rails_reloader_alias
    assert_same Wurk::RailsReloader, Sidekiq::Rails::Reloader
  end

  def test_an_unknown_sidekiq_constant_still_raises
    assert_raises(NameError) { Sidekiq::NoSuchConstant }
  end

  def test_bare_rails_inside_module_sidekiq_is_still_the_top_level_constant
    out, status = Open3.capture2e(RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e', <<~RUBY)
      require 'rails'
      require 'sidekiq'
      module Sidekiq
        print Rails.equal?(::Rails)
      end
    RUBY

    assert_predicate status, :success?, out
    assert_includes out, 'true'
  end

  # --- Sidekiq::Testing --------------------------------------------------

  def test_jobs_clear_empties_that_class_only
    Wurk::Testing.fake! do
      FakeJob.perform_async(1)
      OtherFakeJob.perform_async(2)

      FakeJob.jobs.clear

      assert_empty FakeJob.jobs
      assert_equal 1, OtherFakeJob.jobs.size
    end
  end

  def test_jobs_clear_on_a_class_with_no_jobs_is_harmless
    Wurk::Testing.fake! do
      OtherFakeJob.perform_async(2)

      FakeJob.jobs.clear

      assert_equal 1, OtherFakeJob.jobs.size
    end
  end

  def test_jobs_still_reads_as_an_array
    Wurk::Testing.fake! do
      FakeJob.perform_async(1)

      assert_equal([[1]], FakeJob.jobs.map { |j| j['args'] })
      assert_kind_of Array, FakeJob.jobs
    end
  end

  # --- Sidekiq::Work (7.x surface) ---------------------------------------

  def test_work_raw_reads_a_field
    assert_in_delta 1.5, work.raw('run_at')
  end

  def test_work_index_reads_a_field_without_parsing_it
    assert_equal '{"class":"X"}', work['payload']
    assert_equal 'q', work['queue']
  end

  def test_work_dig_reads_a_field
    args = ['queue']

    assert_equal 'q', work.dig(*args)
  end

  # --- UnitOfWork --------------------------------------------------------

  def test_unit_of_work_takes_the_documented_positional_arguments
    uow = Sidekiq::BasicFetch::UnitOfWork.new('queue:default', '{"jid":"j"}', :config)

    assert_equal 'queue:default', uow.queue
    assert_equal 'default', uow.queue_name
    assert_equal '{"jid":"j"}', uow.job
    assert_equal :config, uow.config
  end

  def test_unit_of_work_still_takes_keywords
    uow = Wurk::Fetcher::Reliable::UnitOfWork.new(queue: 'queue:a', queue_name: 'a', job: 'j', jid: 'x')

    assert_equal 'a', uow.queue_name
    assert_equal 'x', uow.jid
  end

  def test_unit_of_work_without_a_private_list_can_requeue
    uow = Sidekiq::BasicFetch::UnitOfWork.new("queue:#{@queue}", '{"jid":"j"}', Wurk.configuration)

    uow.requeue

    assert_equal(['{"jid":"j"}'], Wurk.redis { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) })
  end

  def test_unit_of_work_without_a_fetcher_acknowledges_as_a_no_op
    assert_nil Sidekiq::BasicFetch::UnitOfWork.new('queue:default', '{}').acknowledge
  end

  private

  def seed(set, extra = {})
    jid = SecureRandom.hex(12)
    payload = { 'class' => 'ThirdPartyGemContractTest::FakeJob', 'args' => [1], 'queue' => @queue, 'jid' => jid,
                'retry' => 3, 'retry_count' => 1, 'created_at' => Time.now.to_f, 'enqueued_at' => Time.now.to_f,
                'error_class' => 'X', 'error_message' => 'y' }.merge(extra)
    json = JSON.generate(payload)
    @dead << json
    Wurk.redis { |c| c.call('ZADD', set.name, (Time.now.to_f + 3600).to_s, json) }
    jid
  end

  def work
    Wurk::Work.new('pid', 'tid', 'queue' => 'q', 'run_at' => 1.5, 'payload' => '{"class":"X"}')
  end
end
