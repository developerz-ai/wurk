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

  private

  def push(unwind)
    Wurk.configuration.client_middleware.add(UJ::Middleware::Client)
    Wurk::Client.push('class' => HardShutdownLockedJob, 'args' => [@log, unwind], 'queue' => @queue)
  ensure
    Wurk.configuration.client_middleware.remove(UJ::Middleware::Client)
  end

  def build_manager
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config.redis = { url: Wurk::Test.redis_url }
    config.server_middleware.add(UJ::Middleware::Server)
    capsule = config.default_capsule
    capsule.queues = [@queue]
    capsule.concurrency = 1
    capsule.prepare!
    Wurk::Manager.new(capsule)
  end

  # A worker process that quiets and runs the block on USR1.
  def fork_worker
    ::Process.fork do
      $stdout.reopen(IO::NULL)
      $stderr.reopen(IO::NULL)
      Wurk.configuration.reset_redis_pools!
      signalled = ::Queue.new
      trap('USR1') { signalled << true }
      manager = build_manager
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
