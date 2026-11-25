# frozen_string_literal: true

require_relative '../test_helper'

# Top-level: the constant has to resolve by name in the forked process.
class HardShutdownLockedJob
  include Wurk::Job

  sidekiq_options lock: :while_executing, lock_ttl: 60, on_conflict: :log, retry: false

  # The run that is told to linger takes `unwind` seconds over its `ensure`, as a
  # job closing a browser or rolling a transaction back does. Every step goes to
  # `log`, in the order Redis saw it.
  def perform(log, unwind)
    run = ::Process.pid == HardShutdownUnwindTest.observer_pid ? 'new' : 'old'
    note(log, "#{run}_in")
    run == 'old' ? sleep : finish(log)
  rescue Wurk::Shutdown
    note(log, 'old_unwinding')
    sleep unwind
    note(log, 'old_unwound')
    raise
  end

  private

  def finish(log)
    sleep 0.3
    note(log, "new_holds_#{Wurk::UniqueJobs.refresh_lock!(self)}")
  end

  def note(log, step) = Wurk.redis { |c| c.call('RPUSH', log, step) }
end

# Another thread's job, slow to unwind.
class HardShutdownSlowJob
  include Wurk::Job

  sidekiq_options retry: false

  def perform
    Wurk.redis { |c| c.call('SET', 'hsu-slow', '1', 'EX', 60) }
    sleep 30
  ensure
    sleep 1.7
  end
end

# Two jobs of one key, so that one can meet the other's lock.
class HardShutdownKeyedJob
  include Wurk::Job

  sidekiq_options lock: :while_executing, lock_ttl: 60, retry: false,
                  lock_args_method: ->(args) { [args[0]] }

  # A later job outlasts whatever holds the first one up.
  def perform(log, name)
    Wurk.redis { |c| c.call('RPUSH', log, "#{name}_in") }
    sleep(name == 'first' && ::Process.pid == HardShutdownUnwindTest.observer_pid ? 0.3 : 5)
    Wurk.redis { |c| c.call('RPUSH', log, "#{name}_done") }
  end
end

class HardShutdownWaitingJob < HardShutdownKeyedJob
  sidekiq_options lock_timeout: 5
end

class HardShutdownRejectedJob < HardShutdownKeyedJob
  sidekiq_options on_conflict: :reject
end

# A deploy in miniature: one process is past its shutdown deadline with a unique
# job in flight, another is already running and fetching the same queue.
class HardShutdownUnwindTest < Wurk::Test::UnitCase
  UJ = Wurk::UniqueJobs
  WAIT = 20

  class << self
    attr_accessor :observer_pid
  end

  def setup
    super
    self.class.observer_pid = ::Process.pid
    UJ.reset!
    @queue = "hsu-#{::Process.pid}-#{object_id}"
    @public = Wurk::Keys.queue(@queue)
    @log = "hsu-log-#{::Process.pid}-#{object_id}"
  end

  def teardown
    UJ.reset!
    @child && reap(@child)
  ensure
    super
  end

  def test_the_next_run_starts_after_the_interrupted_one_unwound_and_holds_the_lock
    push(0.4)
    @child = fork_worker(&:hard_shutdown)
    wait_for_step('old_in')
    manager = build_manager
    ::Process.kill('USR1', @child)
    wait_for_step('old_unwinding')
    manager.start
    wait_for_step(/\Anew_holds/)

    assert_equal %w[old_in old_unwinding old_unwound new_in new_holds_true], steps
    wait_until { Wurk.redis { |c| c.call('KEYS', 'uniquejobs:*:LOCKED') }.empty? }
  ensure
    stop(manager)
  end

  # The thread outlives the wait, so the runs overlap: the lock stays the newer
  # run's through the older one's unwind.
  def test_a_run_that_outlives_the_wait_cannot_free_its_successors_lock
    push(2.15)
    @child = fork_worker { |manager| manager.hard_shutdown && sleep(1) }
    wait_for_step('old_in')
    manager = build_manager
    ::Process.kill('USR1', @child)
    manager.start
    wait_for_step(/\Anew_holds/)

    assert_operator steps.index('new_in'), :<, steps.index('old_unwound'), 'the runs were meant to overlap'
    assert_equal 'new_holds_true', steps.last
  ensure
    stop(manager)
  end

  # SIGKILL anywhere before the move: the payload is still in the dead process's
  # private list, once, and the reaper brings it back.
  def test_a_sigkill_while_unwinding_loses_nothing
    push(30)
    @child = fork_worker(&:hard_shutdown)
    wait_for_step('old_in')
    ::Process.kill('USR1', @child)
    wait_for_step('old_unwinding')
    ::Process.kill('KILL', @child)
    ::Process.wait(@child)
    dead = private_lists

    assert_equal 0, queue_size
    assert_equal 1, dead.size
    assert_equal(1, Wurk.redis { |c| c.call('LLEN', dead.first) })

    manager = build_manager
    Wurk.redis { |c| c.call('LMOVE', dead.first, @public, 'RIGHT', 'RIGHT') }
    manager.start
    wait_for_step(/\Anew_holds/)

    assert_equal 'new_holds_true', steps.last, 'the recovered job did not re-enter its dead run\'s lock'
  ensure
    stop(manager)
  end

  # While one thread is slow to unwind, the other's job must not lose its lock to a
  # later job of the same key and come back to a conflict, which drops it (no
  # strategy), buries it (`reject`) or pushes it again as another job (`reschedule`).
  # `lock_timeout` is the case no speed of requeue can win: the later job is
  # already waiting when the lock is let go.
  %w[Keyed Waiting Rejected].each do |kind|
    define_method("test_an_interrupted_#{kind.downcase}_job_is_not_lost_to_a_later_one_of_its_key") do
      klass = Object.const_get("HardShutdown#{kind}Job")
      push_class(klass, @log, 'first')
      push_class(HardShutdownSlowJob)
      Wurk.redis { |c| c.call('DEL', 'hsu-slow') }
      @child = fork_worker(concurrency: 2, &:hard_shutdown)
      wait_for_step('first_in')
      wait_until { Wurk.redis { |c| c.call('GET', 'hsu-slow') } }
      manager = build_manager(concurrency: 4)
      manager.start
      push_class(klass, @log, 'later')
      sleep 0.2
      ::Process.kill('USR1', @child)
      sleep 0.3
      push_class(klass, @log, 'later_still')
      wait_for_step('first_done')

      assert_equal 2, steps.count('first_in'), 'the interrupted job must run again'
      refute_includes Wurk.redis { |c| c.call('ZRANGE', 'dead', 0, -1) }.join, '"first"'
    ensure
      stop(manager)
    end
  end

  private

  def push_class(klass, *args)
    Wurk.configuration.client_middleware.add(UJ::Middleware::Client)
    Wurk::Client.push('class' => klass, 'args' => args, 'queue' => @queue)
  ensure
    Wurk.configuration.client_middleware.remove(UJ::Middleware::Client)
  end

  def push(unwind)
    push_class(HardShutdownLockedJob, @log, unwind)
  end

  def build_manager(concurrency: 1)
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config.redis = { url: Wurk::Test.redis_url }
    config.server_middleware.add(UJ::Middleware::Server)
    capsule = config.default_capsule
    capsule.queues = [@queue]
    capsule.concurrency = concurrency
    capsule.prepare!
    Wurk::Manager.new(capsule)
  end

  # A worker process that quiets and runs the block on USR1.
  def fork_worker(concurrency: 1)
    ::Process.fork do
      $stdout.reopen(IO::NULL)
      $stderr.reopen(IO::NULL)
      Wurk.configuration.reset_redis_pools!
      signalled = ::Queue.new
      trap('USR1') { signalled << true }
      manager = build_manager(concurrency: concurrency)
      manager.start
      signalled.pop
      manager.quiet
      yield manager
      exit!(0)
    end
  end

  def stop(manager)
    return unless manager

    manager.stop(::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 5)
    manager.capsule.config.reset_redis_pools!
  end

  def reap(pid)
    ::Process.kill('KILL', pid)
    ::Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def steps = Wurk.redis { |c| c.call('LRANGE', @log, 0, -1) }
  def queue_size = Wurk.redis { |c| c.call('LLEN', @public) }
  def private_lists = Wurk.redis { |c| c.call('KEYS', "#{@public}|*") }
  def wait_for_step(step) = wait_until { steps.any? { |s| step === s } } # rubocop:disable Style/CaseEquality

  def wait_until
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + WAIT
    until yield
      flunk "condition not met in time; steps: #{steps.inspect}" if
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end
end
