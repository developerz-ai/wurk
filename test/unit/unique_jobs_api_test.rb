# frozen_string_literal: true

require_relative '../test_helper'

# The parts of Wurk::UniqueJobs apps call directly, and the edges of the lock
# types: the inspection classes, the API extension (on subclasses, so the
# prepend never leaks into other tests), callbacks and odd options.
class UniqueJobsApiTest < Wurk::Test::UnitCase
  UJ = Wurk::UniqueJobs

  module Jobs
    class Plain
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_args_method: ->(args) { [args[0]] }
    end

    class WithItemHook
      include Wurk::Job

      sidekiq_options lock: :until_executed

      class << self
        attr_accessor :seen

        def after_unlock(item) = (self.seen = item['jid'])
      end
    end

    class FailingHook
      include Wurk::Job

      sidekiq_options lock: :until_executing

      def self.after_unlock = raise('hook broke')
    end

    class SymbolTtl
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_ttl: :ttl_for
      def self.ttl_for(args) = args[0]
    end

    class OldStyleArgs
      include Wurk::Job

      sidekiq_options lock: :until_executed
      def self.unique_args(args) = [args[1]]
    end

    class Waiting
      include Wurk::Job

      sidekiq_options lock: :while_executing, lock_timeout: 0, on_conflict: :log
    end

    class Infoed
      include Wurk::Job

      sidekiq_options lock: :until_executed, lock_info: true, lock_ttl: 30
    end
  end

  def setup
    super
    UJ.reset!
    @server = Wurk::Middleware::Chain.new(Wurk.configuration)
    @server.add(UJ::Middleware::Server)
  end

  def teardown
    UJ.reset!
    UJ.instance_variable_set(:@reflections, nil)
  ensure
    super
  end

  def item(klass, *args, **extra)
    { 'class' => klass.name, 'queue' => 'default', 'args' => args, 'jid' => SecureRandom.hex(12) }
      .merge(extra.transform_keys(&:to_s))
  end

  def lock!(klass, *, **extra)
    job = UJ::Job.prepare(item(klass, *, **extra))
    UJ::Locksmith.new(job).lock
    job
  end

  def perform(job, worker = Wurk.const_get(job['class']).new, &block)
    ran = false
    @server.invoke(worker, job, job['queue']) do
      ran = true
      block&.call
    end
    ran
  end

  # ---- inspection ---------------------------------------------------------

  def test_lock_reads_what_a_digest_holds
    UJ.config.max_history = 10
    UJ.config.lock_info = true
    job = lock!(Jobs::Infoed, 1)
    lock = UJ::Lock.new(job['lock_digest'])

    assert_equal [job['jid']], lock.locked_jids
    assert_equal [job['jid']], lock.locked_jids(with_values: true).keys
    assert_equal [job['jid']], lock.all_jids
    assert_empty lock.queued_jids + lock.primed_jids
    assert_equal 'UniqueJobsApiTest::Jobs::Infoed', lock.info['worker']
    assert_kind_of Float, lock.created_at
    assert_match(/Lock status for uniquejobs:/, lock.to_s)
    assert_same lock.key, UJ::Lock.new(lock.key).key
    lock.unlock(job['jid'])

    assert_empty lock.locked_jids
    lock.del

    assert_predicate UJ::Lock.new(job['lock_digest']).info, :none?
    assert_equal 0, UJ::Digests.new.count
  end

  def test_sorted_sets_page_score_and_range
    digests = UJ::Digests.new
    digests.add('uniquejobs:a')
    expiring = UJ::ExpiringDigests.new
    Wurk.redis { |c| c.call('ZADD', 'uniquejobs:expiring_digests', 5, 'uniquejobs:b') }

    assert_equal 'uniquejobs:expiring_digests', expiring.key
    assert_in_delta Time.now.to_f, digests.score('uniquejobs:a'), 5
    assert_nil digests.score('uniquejobs:none')
    assert_equal ['uniquejobs:b'], expiring.byscore(0, 10)
    assert_equal ['uniquejobs:b'], expiring.byscore(0, 10, offset: 0, count: 1)
    expiring.delete_by_digest('uniquejobs:b')

    assert_empty expiring.entries
  end

  def test_changelog_add_page_and_clear
    log = UJ::Changelog.new
    log.add(message: 'Locked', job_id: 'j', script: 'lock.lua', digest: 'uniquejobs:x')
    _size, _cursor, entries = log.page

    assert_equal 'Locked', entries.first['message']
    log.clear

    assert_empty log.entries
  end

  def test_unlockable_recomputes_the_digest_from_the_payload
    job = lock!(Jobs::Plain, 7, 'x')
    bare = job.slice('class', 'queue', 'args', 'jid', 'lock')

    assert_equal job['jid'], UJ::Unlockable.unlock!(bare.dup)
    lock!(Jobs::Plain, 7, 'x')

    assert UJ::Unlockable.delete!(bare.dup)
    assert_nil UJ::Unlockable.delete(bare.merge('lock_ttl' => 60)), 'delete keeps a lock with a TTL'
    # Held by nobody: the gem's unlock clears what is left and answers with the jid.
    assert_equal job['jid'], UJ::Unlockable.unlock(bare.dup)
  end

  # ---- the API extension, on stand-ins ------------------------------------

  def test_api_extension_releases_on_every_delete_path
    queue_class = Class.new(Wurk::Queue) { prepend UJ::APIExtension::ClearEach }
    record_class = Class.new(Wurk::JobRecord) { prepend UJ::APIExtension::JobRecord }
    set_class = Class.new(Wurk::ScheduledSet) do
      prepend UJ::APIExtension::ClearEach
      prepend UJ::APIExtension::JobSet
      prepend UJ::APIExtension::ScheduledSet
    end
    entry_class = Class.new(Wurk::SortedEntry) { prepend UJ::APIExtension::SortedEntry }
    push = lambda do |arg, at: nil|
      job = lock!(Jobs::Plain, arg)
      raw = Wurk.dump_json(job)
      if at
        Wurk.redis { |c| c.call('ZADD', 'schedule', at, raw) }
      else
        Wurk.redis do |c|
          c.call('LPUSH', 'queue:default', raw)
        end
      end
      raw
    end
    free = ->(arg) { !UJ::Locksmith.new(UJ::Job.prepare(item(Jobs::Plain, arg))).lock.nil? }

    raw = push.call('record')
    record_class.new(raw, 'default').delete
    push.call('cleared')
    queue_class.new('default').clear
    sched = push.call('by_jid', at: 10)
    set_class.new.delete(10, Wurk.load_json(sched)['jid'])
    raw = push.call('entry', at: 11)
    entry_class.new(set_class.new, 11, raw).delete
    push.call('set_cleared', at: 12)
    set_class.new.clear
    raw = push.call('removed', at: 13)
    dead = Wurk::DeadSet.new
    entry_class.new(set_class.new, 13, raw).send(:remove_job) { |message| dead.kill(message, notify_failure: false) }

    assert(%w[record cleared by_jid entry set_cleared removed].all? { |arg| free.call(arg) },
           'a deleted job left its lock behind')
    refute free.call('record'), 'the lock just taken again must hold'
  end

  def test_api_extension_ignores_jobs_without_locks_and_unreadable_members
    assert_nil UJ::APIExtension.release('class' => 'X', 'args' => [])
    assert_nil UJ::APIExtension.release('not a hash')
    assert_nil UJ::APIExtension.release_raw('not json')
  end

  # ---- callbacks and lock-type edges --------------------------------------

  def test_after_unlock_with_an_argument_gets_the_payload
    job = lock!(Jobs::WithItemHook, 1)

    assert perform(job, Jobs::WithItemHook)
    assert_equal job['jid'], Jobs::WithItemHook.seen
  end

  def test_a_failing_after_unlock_is_reported_and_the_job_still_runs
    failed = []
    UJ.reflect { |on| on.after_unlock_callback_failed { |_item, error| failed << error.message } }
    job = lock!(Jobs::FailingHook, 1)

    assert perform(job)
    assert_equal ['hook broke'], failed
  end

  def test_reflections_report_a_failed_unlock_and_a_reflection_that_raises
    events = []
    UJ.reflect do |on|
      on.unlock_failed { |_item| events << :unlock_failed }
      on.locked { |_item| raise UJ::UniqueJobsError, 'in the hook' }
    end
    job = UJ::Job.prepare(item(Jobs::Plain, 1))
    UJ::Locksmith.new(job.merge('jid' => 'other')).lock
    UJ::Lock::UntilExecuted.new(job, nil).send(:unlock_and_callback)

    assert_equal [:unlock_failed], events
    assert_nil UJ::Lock::BaseLock.new(job, nil).send(:reflect, :locked, job)
  end

  def test_until_and_while_executing_skips_a_job_whose_push_lock_another_holds
    job = UJ::Job.prepare(item(Jobs::Plain, 1, lock: 'until_and_while_executing'))
    UJ::Locksmith.new(job.merge('jid' => 'holder')).lock

    refute perform(job)
  end

  def test_while_executing_waits_out_lock_timeout_and_then_reports_a_timeout
    timeouts = []
    UJ.reflect { |on| on.timeout { |_item| timeouts << :timeout } }
    holder = UJ::Job.prepare(item(Jobs::Waiting, 1))
    UJ::Lock::WhileExecuting.new(holder, nil)
    # Another job queued ahead for the runtime lock: the wait pops its jid, not ours.
    Wurk.redis { |c| c.call('LPUSH', "#{holder['lock_digest']}:QUEUED", 'someone') }
    other = UJ::Job.prepare(item(Jobs::Waiting, 1))

    refute perform(other)
    assert_equal [:timeout], timeouts
  end

  def test_while_executing_takes_no_push_lock
    job = UJ::Job.prepare(item(Jobs::Waiting, 1))
    pushed = UJ::Lock::WhileExecuting.new(job, nil).lock { :pushed }

    assert_equal job['jid'], pushed
    assert job['lock_digest'].end_with?(':RUN')
    assert_equal job['lock_digest'], UJ::Lock::WhileExecuting.new(job, nil).send(:item)['lock_digest']
  end

  def test_base_lock_and_strategy_insist_on_their_contracts
    job = UJ::Job.prepare(item(Jobs::Plain, 1))
    base = UJ::Lock::BaseLock.new(job, nil)

    assert_raises(NotImplementedError) { base.lock }
    assert_raises(NotImplementedError) { base.execute }
    assert_raises(UJ::InvalidArgument) { base.send(:strategy_for, :elsewhere) }
    assert_raises(NotImplementedError) { UJ::OnConflict::Strategy.new(job).call }
    assert_raises(UJ::InvalidArgument) { UJ::Locksmith.new(job).execute }
  end

  # The gem's guards on a blocking wait: a negative wait raises once the job is
  # queued for the lock, a non-integer one before Redis is asked.
  def test_a_blocking_wait_must_be_a_positive_integer
    locksmith = UJ::Locksmith.new(UJ::Job.prepare(item(Jobs::Plain, 1)))

    assert_raises(UJ::InvalidArgument) { locksmith.lock(wait: -1) }
    Wurk.redis do |conn|
      assert_raises(UJ::InvalidArgument) { locksmith.send(:pop_queued, conn, 1.5) }
    end
  ensure
    locksmith.delete!
  end

  def test_until_expired_reports_a_run_it_could_not_lock
    failed = []
    UJ.reflect { |on| on.execution_failed { |_item| failed << :failed } }
    job = UJ::Job.prepare(item(Jobs::Plain, 1, lock: 'until_expired', lock_ttl: 30))
    UJ::Locksmith.new(job.merge('jid' => 'other')).lock

    assert_nil(UJ::Lock::UntilExpired.new(job, nil).execute { flunk 'ran without the lock' })
    assert_equal [:failed], failed
  end

  def test_lock_info_is_written_when_asked
    job = lock!(Jobs::Infoed, 3, lock_info: true)
    info = Wurk.load_json(Wurk.redis { |c| c.call('GET', "#{job['lock_digest']}:INFO") })

    assert_equal [3], info['lock_args']
    assert_equal 'until_executed', info['type']
  end

  # ---- options ------------------------------------------------------------

  def test_ttl_from_a_symbol_and_old_style_unique_args
    assert_equal 9, UJ::Job.prepare(item(Jobs::SymbolTtl, 9))['lock_ttl']
    assert_equal ['b'], UJ::Job.prepare(item(Jobs::OldStyleArgs, 'a', 'b'))['lock_args']
    assert_raises(ArgumentError) { UJ::Job.prepare(item(Jobs::Plain, 1, lock_ttl: Object.new)) }
    assert_equal 5, UJ::Job.prepare(item(Jobs::Plain, 1, lock_ttl: 5.0, lock_expiration: 99))['lock_ttl']
  end

  def test_a_symbol_lock_args_method_the_class_lacks_covers_every_argument
    job = UJ::Job.prepare(item(Jobs::Plain, 1, 2).merge('class' => 'NotLoaded'))
    klass = Class.new { include Wurk::Job }
    klass.sidekiq_options(lock: :until_executed, lock_args_method: :missing)
    self.class.const_set(:Missing, klass)

    assert_equal [1, 2], job['lock_args']
    assert_equal [1, 2], UJ::Job.prepare(item(klass, 1, 2))['lock_args']
  ensure
    self.class.send(:remove_const, :Missing) if self.class.const_defined?(:Missing, false)
  end

  def test_constantize_and_deep_stringify
    assert_equal Wurk::UniqueJobs::Lock, UJ.constantize('::Wurk::UniqueJobs::Lock')
    assert_equal Jobs::Plain, UJ.constantize(Jobs::Plain.new)
    assert_equal 'Nope::Nada', UJ.safe_constantize('Nope::Nada')
    assert_raises(NameError) { UJ.safe_constantize('lowercase') }
    assert_equal [{ 'a' => [{ 'b' => 1 }] }], UJ.deep_stringify([{ a: [{ b: 1 }] }])
  end

  def test_module_level_helpers
    out = StringIO.new
    UJ.logger = Logger.new(out)
    UJ.config.logger_enabled = true
    UJ::OnConflict::Log.new('jid' => 'j1', 'lock_digest' => 'uniquejobs:d').call
    strategy = UJ::OnConflict.find_strategy(:nonsense)

    assert_match(/Skipping job with id \(j1\)/, out.string)
    assert_equal UJ::OnConflict::NullStrategy, strategy
    assert_match(/No matching implementation for strategy: nonsense/, out.string)
    assert_equal 'm (lock=x jid=j)', UJ::OnConflict::Log.new({}).build_message('m', 'lock' => 'x', 'jid' => 'j')
    assert_nil UJ::OnConflict::NullStrategy.new({}).call
    assert_raises(ArgumentError) { UJ.use_config }
    assert_nil UJ.validate_worker!(lock: :until_executed)
    assert_equal '8.1.0', UJ.version
    UJ.disable!

    assert_predicate UJ, :disabled?
  end

  def test_config_redis_version_and_aliases
    UJ.config.default_lock_ttl = 9
    UJ.config.default_lock_timeout = 2

    assert_equal [9, 2], [UJ.config.default_lock_ttl, UJ.config.default_lock_timeout]
    assert_match(/\A\d+\.\d+/, UJ.config.redis_version)
    assert_same UJ.config.redis_version, UJ.config.redis_version
    assert_nil UJ.config.shutdown_executor
  end

  def test_reschedule_reports_a_class_it_cannot_push
    seen = []
    UJ.reflect { |on| on.unknown_sidekiq_worker { |_item| seen << :unknown } }
    UJ::OnConflict::Reschedule.new('class' => 'NotLoaded', 'queue' => 'q', 'args' => []).call

    assert_equal [:unknown], seen
  end

  def test_replace_with_no_queued_holder_does_nothing
    called = false
    UJ::OnConflict::Replace.new(UJ::Job.prepare(item(Jobs::Plain, 1))).call { called = true }

    refute called
  end

  # ---- server wiring --------------------------------------------------------

  def test_server_configure_wires_startup_shutdown_and_death_once
    config = Wurk::Configuration.new
    2.times { UJ::Server.configure(config) }

    assert_equal 1, config.death_handlers.count(UJ::Server.death_handler)
    UJ.config.reaper = :none
    hooks = config[:lifecycle_events]

    assert_nil hooks[:startup].last.call
    assert_nil hooks[:shutdown].last.call
  end

  def test_the_reaper_thread_runs_and_stops
    UJ.config.reaper_interval = 3600
    Wurk.redis do |c|
      c.call('SET', 'uniquejobs:stale', 'j')
      c.call('ZADD', 'uniquejobs:digests', 1, 'uniquejobs:stale')
    end
    thread = UJ::Orphans::Manager.start

    assert_same thread, UJ::Orphans::Manager.start, 'a second start made a second thread'
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.05 until Wurk.redis { |c| c.call('ZCARD', 'uniquejobs:digests') }.zero? ||
                     Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    assert_equal(0, Wurk.redis { |c| c.call('ZCARD', 'uniquejobs:digests') })
    assert_equal(1, UJ::Orphans::Manager.tick.then { Wurk.redis { |c| c.call('EXISTS', 'uniquejobs:reaper') } })
    UJ::Orphans::Manager.stop

    refute_predicate thread, :alive?
    assert_equal(0, Wurk.redis { |c| c.call('EXISTS', 'uniquejobs:reaper') })
  end

  def test_a_tick_that_raises_is_logged_and_the_loop_goes_on
    out = StringIO.new
    UJ.logger = Logger.new(out)
    manager = UJ::Orphans::Manager
    original = manager.method(:tick)
    manager.instance_variable_set(:@stop, false)
    manager.instance_variable_set(:@wake, Thread::Queue.new)
    manager.define_singleton_method(:tick) do
      instance_variable_set(:@stop, true)
      raise RedisClient::CannotConnectError, 'down'
    end
    manager.send(:run)

    assert_match(/uniquejobs reaper: RedisClient::CannotConnectError: down/, out.string)
  ensure
    manager.define_singleton_method(:tick, original)
  end

  # With the gem loaded instead, a native middleware does nothing and says so once.
  def test_native_middleware_stands_down_when_the_gem_is_loaded
    out = StringIO.new
    UJ.logger = Logger.new(out)
    original = Wurk::UniqueJobsCompat.method(:gem_present?)
    Wurk::UniqueJobsCompat.define_singleton_method(:gem_present?) { true }
    UJ.instance_variable_set(:@native, nil)
    job = item(Jobs::Plain, 1)

    2.times { assert perform(job.dup) }

    assert_equal 1, out.string.scan('gem is loaded').size
    assert_empty(Wurk.redis { |c| c.call('KEYS', 'uniquejobs:*') })
  ensure
    Wurk::UniqueJobsCompat.define_singleton_method(:gem_present?, original)
    UJ.instance_variable_set(:@native, nil)
    UJ.instance_variable_set(:@stand_down_warned, nil)
  end
end
