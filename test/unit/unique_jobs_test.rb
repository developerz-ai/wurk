# frozen_string_literal: true

require_relative '../test_helper'
require 'openssl'

# How Wurk::UniqueJobs derives a payload's lock fields. The digest has to be the
# one sidekiq-unique-jobs 8.1 computes, byte for byte, or a fleet running both
# would hold two locks for one job: each expectation is the gem's documented
# formula, `"uniquejobs:" + MD5(JSON(sorted class/queue/lock_args))`, written out.
# test/ecosystem/sidekiq-unique-jobs-native/interop.rb holds it against the gem.
class UniqueJobsTest < Wurk::Test::UnitCase
  module Jobs
    class ProcArgs
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_args_method: ->(args) { [args[0]] }
    end

    class SymbolArgs
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_args_method: :pick
      def self.pick(args) = args.last(1)
    end

    class ImplicitLockArgs
      include Wurk::Job

      sidekiq_options lock: :while_executing
      def self.lock_args(args) = [args[1]]
    end

    class AllArgs
      include Wurk::Job

      sidekiq_options lock: :until_executed
    end

    class StringMethod
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_args_method: 'pick'
    end

    class AcrossQueues
      include Wurk::Job

      sidekiq_options lock: :until_executed, unique_across_queues: true
    end

    class AcrossWorkers
      include Wurk::Job

      sidekiq_options lock: :until_executed, unique_across_workers: true
    end

    class Ttls
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_ttl: ->(args) { args[0] * 2 }, lock_timeout: 3
    end

    class BadArity
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_args_method: :pick
      def self.pick = []
    end
  end

  def setup
    super
    Wurk::UniqueJobs.reset!
  end

  def teardown
    Wurk::UniqueJobs.reset!
  ensure
    super
  end

  def prepare(klass, args, **extra)
    item = { 'class' => klass.is_a?(String) ? klass : klass.name, 'queue' => 'default', 'args' => args,
             'jid' => 'j1' }.merge(extra.transform_keys(&:to_s))
    Wurk::UniqueJobs::Job.prepare(item)
  end

  def gem_digest(hash, prefix = 'uniquejobs')
    "#{prefix}:#{OpenSSL::Digest::MD5.hexdigest(JSON.generate(hash.sort))}"
  end

  def test_digest_is_the_gems_md5_of_class_queue_and_lock_args
    item = prepare(Jobs::ProcArgs, [1, 'ignored'])

    assert_equal [1], item['lock_args']
    assert_equal gem_digest('class' => Jobs::ProcArgs.name, 'queue' => 'default', 'lock_args' => [1]),
                 item['lock_digest']
  end

  def test_lock_args_method_forms_resolve_as_the_gem_resolves_them
    assert_equal [3], prepare(Jobs::SymbolArgs, [1, 2, 3])['lock_args']
    assert_equal [2], prepare(Jobs::ImplicitLockArgs, [1, 2, 3])['lock_args']
    assert_equal [1, { 'a' => 1 }], prepare(Jobs::AllArgs, [1, { 'a' => 1 }])['lock_args']
    # The gem filters only through a Proc or a Symbol; a String method name covers nothing.
    assert_empty prepare(Jobs::StringMethod, [1, 2])['lock_args']
  end

  def test_the_method_sees_the_arguments_after_a_json_round_trip
    seen = nil
    klass = Class.new do
      include Wurk::Job
    end
    klass.sidekiq_options(lock: :until_executed, lock_args_method: lambda { |args|
      seen = args
      args
    })
    self.class.const_set(:RoundTrip, klass)
    prepare(klass, [{ sym: :value }])

    assert_equal [{ 'sym' => 'value' }], seen
  ensure
    self.class.send(:remove_const, :RoundTrip) if self.class.const_defined?(:RoundTrip, false)
  end

  def test_across_queues_and_workers_drop_their_field_from_the_digest
    assert_equal gem_digest('class' => Jobs::AcrossQueues.name, 'lock_args' => [1]),
                 prepare(Jobs::AcrossQueues, [1])['lock_digest']
    assert_equal gem_digest('queue' => 'default', 'lock_args' => [1]), prepare(Jobs::AcrossWorkers, [1])['lock_digest']
  end

  def test_apartment_prefix_and_modern_algorithm
    with_apartment = prepare(Jobs::AllArgs, [1], apartment: 'tenant')

    assert_equal gem_digest('class' => Jobs::AllArgs.name, 'queue' => 'default', 'lock_args' => [1],
                            'apartment' => 'tenant'), with_apartment['lock_digest']
    assert_equal gem_digest({ 'class' => Jobs::AllArgs.name, 'queue' => 'default', 'lock_args' => [1] }, 'mine'),
                 prepare(Jobs::AllArgs, [1], lock_prefix: 'mine')['lock_digest']

    Wurk::UniqueJobs.config.digest_algorithm = :modern
    json = JSON.generate({ 'class' => Jobs::AllArgs.name, 'queue' => 'default', 'lock_args' => [1] }.sort)

    assert_equal "uniquejobs:#{OpenSSL::Digest.new('SHA3-256', json).hexdigest}",
                 prepare(Jobs::AllArgs, [1])['lock_digest']
    assert_raises(ArgumentError) { Wurk::UniqueJobs.config.digest_algorithm = :md5 }
  end

  def test_an_unloaded_class_digests_by_name_over_every_argument
    item = prepare('NotLoaded::Job', [1, 2])

    assert_equal gem_digest('class' => 'NotLoaded::Job', 'queue' => 'default', 'lock_args' => [1, 2]),
                 item['lock_digest']
  end

  def test_ttl_and_timeout_resolve_option_then_config
    assert_nil prepare(Jobs::AllArgs, [1])['lock_ttl']
    Wurk::UniqueJobs.config.lock_ttl = 7200

    assert_equal 7200, prepare(Jobs::AllArgs, [1])['lock_ttl']
    assert_equal 10, prepare(Jobs::Ttls, [5])['lock_ttl']
    assert_equal 3, prepare(Jobs::Ttls, [5])['lock_timeout']
    assert_equal 0, prepare(Jobs::AllArgs, [1])['lock_timeout']

    Wurk::UniqueJobs.config.lock_timeout = nil

    assert_nil prepare(Jobs::AllArgs, [1])['lock_timeout']
  end

  # The gem adds the wait until `at` at push time, so the lock spans the wait.
  def test_a_scheduled_job_adds_its_wait_to_the_ttl
    Wurk::UniqueJobs.config.lock_ttl = 100
    ttl = prepare(Jobs::AllArgs, [1], at: Time.now.to_f + 50)['lock_ttl']

    assert_includes 149..150, ttl
  end

  def test_a_lock_args_method_of_the_wrong_arity_names_itself
    error = assert_raises(Wurk::UniqueJobs::InvalidUniqueArguments) { prepare(Jobs::BadArity, [1]) }

    assert_match(/BadArity#pick takes 0 arguments/, error.message)
  end

  def test_validator_reports_deprecated_keys_and_conflicts_the_gem_rejects
    assert_equal %i[unique unique_args lock_args unique_prefix],
                 Wurk::UniqueJobs::Lock::Validator::DEPRECATED_KEYS.keys
    config = Wurk::UniqueJobs.validate_worker(lock: :until_executed, on_conflict: :reject, unique_args: :x)

    assert_equal %i[unique_args on_client_conflict], config.errors.keys
    assert_empty Wurk::UniqueJobs.validate_worker(lock: :while_executing, on_conflict: :reschedule).errors
    assert_raises(Wurk::UniqueJobs::NotUniqueWorker) { Wurk::UniqueJobs.validate_worker(queue: 'q') }
    assert_raises(Wurk::UniqueJobs::InvalidWorker) do
      Wurk::UniqueJobs.validate_worker!(lock: :until_executed, on_conflict: { client: :replace, server: :replace })
    end
  end

  def test_on_conflict_hash_splits_by_side
    config = Wurk::UniqueJobs::LockConfig.new('lock' => 'until_executed',
                                              'on_conflict' => { 'client' => :log, 'server' => :reschedule })

    assert_equal :log, config.on_client_conflict
    assert_equal :reschedule, config.on_server_conflict
    assert_equal :reject, Wurk::UniqueJobs::LockConfig.new('on_conflict' => :reject).on_server_conflict
  end

  def test_configure_takes_the_gems_knobs
    Wurk::UniqueJobs.configure do |config|
      config.lock_ttl = 7200
      config.lock_timeout = nil
      config.enabled = false
      config.debug_lua = false
      config.lock_info = false
      config.max_history = 0
      config.reaper = :none
      config.reaper_count = 5000
      config.reaper_interval = 600
      config.reaper_timeout = 300
    end

    refute_predicate Wurk::UniqueJobs, :enabled?
    assert_equal 5000, Wurk::UniqueJobs.config.reaper_count
    Wurk::UniqueJobs.use_config(lock_ttl: 5) { assert_equal 5, Wurk::UniqueJobs.config.lock_ttl }

    assert_equal 7200, Wurk::UniqueJobs.config.lock_ttl
    assert_same Wurk.logger, Wurk::UniqueJobs.logger
  end

  def test_toggle_restores_the_flag
    Wurk::UniqueJobs.disable! { refute_predicate Wurk::UniqueJobs, :enabled? }

    assert_predicate Wurk::UniqueJobs, :enabled?
  end

  def test_custom_locks_and_strategies_register_once
    Wurk::UniqueJobs.config.add_lock(:custom, Wurk::UniqueJobs::Lock::UntilExecuted)
    Wurk::UniqueJobs.config.add_strategy(:custom, Wurk::UniqueJobs::OnConflict::Log)

    assert_equal Wurk::UniqueJobs::Lock::UntilExecuted, Wurk::UniqueJobs.locks[:custom]
    assert_raises(Wurk::UniqueJobs::DuplicateLock) { Wurk::UniqueJobs.config.add_lock(:custom, Object) }
    assert_raises(Wurk::UniqueJobs::DuplicateStrategy) { Wurk::UniqueJobs.config.add_strategy(:log, Object) }
  end

  def test_reflections_dispatch_to_a_registered_block
    seen = []
    Wurk::UniqueJobs.reflections.lock_failed { |item| seen << item }
    Wurk::UniqueJobs.reflections.dispatch(:lock_failed, 'x')

    assert_equal ['x'], seen
    assert_raises(Wurk::UniqueJobs::NoSuchNotificationError) { Wurk::UniqueJobs.reflections.dispatch(:nope) }
    assert_raises(Wurk::UniqueJobs::NoBlockGiven) { Wurk::UniqueJobs.reflections.locked }
  ensure
    Wurk::UniqueJobs.instance_variable_set(:@reflections, nil)
  end

  # A script the server reports as failed raises the gem's class, so an app's
  # rescue of it still applies; other Redis errors (Redis 7 words a runtime
  # script error differently) pass through unchanged, as the gem lets them.
  def test_script_errors_are_wrapped_where_the_gem_wraps_them
    wrapped = RedisClient::CommandError.new('ERR Error running script (call to f_x): @user_script:3: boom')
    lua = Wurk::UniqueJobs::Script::LuaError.new(wrapped, Wurk::UniqueJobs::Script::Source.new('x.lua', 'src'))

    assert Wurk::UniqueJobs::Script::LuaError.intercepts?(wrapped)
    assert_equal 'x.lua', lua.file
    assert_same wrapped, lua.error
    # Dragonfly words this failure the way the gem's pattern reads; Redis 7 does not.
    error = Wurk.redis do |conn|
      assert_raises(RedisClient::CommandError, Wurk::UniqueJobs::Script::LuaError) do
        Wurk::UniqueJobs::Script.call(:unique_jobs_queue_and_lock, conn, keys: Array.new(8, 'k'), argv: [])
      end
    end
    wrapped_by_us = error.is_a?(Wurk::UniqueJobs::Script::LuaError)
    raw = wrapped_by_us ? error.error : error

    assert_kind_of RedisClient::CommandError, raw
    assert_equal Wurk::UniqueJobs::Script::LuaError.intercepts?(raw), wrapped_by_us
  end
end
