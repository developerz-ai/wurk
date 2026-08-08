# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::Manager with a real Capsule + real Reliable fetcher + real
# Redis. Each test owns a unique queue/private list so parallel runs can't
# collide on either Redis state or worker constants. Where possible we avoid
# spawning processor threads — the public surface (workers Set, stopped?,
# processor_result, hard_shutdown wiring) is exercised directly.
class ManagerTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @queue_name = "mt-#{Process.pid}-#{object_id}"
    @public_queue = "#{Wurk::Keys::QUEUE_PREFIX}#{@queue_name}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @capsule = Wurk::Capsule.new('test', @config)
    @capsule.queues = [@queue_name]
    @capsule.concurrency = 3
    @capsule.fetcher = Wurk::Fetcher::Reliable.new(@capsule)
    @pool = @capsule.redis_pool
  end

  def teardown
    @pool.with { |c| c.call('DEL', @public_queue, private_queue) }
  ensure
    super
  end

  # --- initialization --------------------------------------------------

  def test_initialize_spawns_concurrency_processors
    mgr = Wurk::Manager.new(@capsule)

    assert_equal 3, mgr.workers.size
    mgr.workers.each { |w| assert_kind_of Wurk::Processor, w }
  end

  def test_initialize_exposes_capsule
    mgr = Wurk::Manager.new(@capsule)

    assert_same @capsule, mgr.capsule
  end

  def test_initialize_starts_not_stopped
    mgr = Wurk::Manager.new(@capsule)

    refute_predicate mgr, :stopped?
  end

  def test_initialize_raises_on_zero_concurrency
    @capsule.concurrency = 0

    assert_raises(ArgumentError) { Wurk::Manager.new(@capsule) }
  end

  def test_initialize_raises_on_negative_concurrency
    @capsule.concurrency = -1

    assert_raises(ArgumentError) { Wurk::Manager.new(@capsule) }
  end

  # --- start -----------------------------------------------------------

  def test_start_invokes_start_on_every_processor
    mgr = Wurk::Manager.new(@capsule)
    started = []
    mgr.workers.each { |w| w.define_singleton_method(:start) { started << self } }

    mgr.start

    assert_equal mgr.workers.to_a, started
  end

  # start iterates a @plock snapshot, not the live Set, so a Processor that
  # dies (mutating @workers via processor_result) while its siblings are still
  # being started can't trigger "can't add a new key into hash during
  # iteration". Deterministic stand-in for real replace-on-die churn.
  def test_start_iterates_a_snapshot_so_mid_iteration_churn_is_safe
    mgr = Wurk::Manager.new(@capsule)
    workers = mgr.workers.to_a
    workers.each { |w| w.define_singleton_method(:start) { nil } }
    victim = workers.last
    workers.first.define_singleton_method(:start) { mgr.processor_result(victim) }

    with_processor_new(fake_processor) { mgr.start }

    refute_includes mgr.workers, victim
  end

  # --- quiet -----------------------------------------------------------

  def test_quiet_flips_stopped_and_terminates_each_processor
    mgr = Wurk::Manager.new(@capsule)
    seen = []
    mgr.workers.each { |w| w.define_singleton_method(:terminate) { seen << self } }

    mgr.quiet

    assert_predicate mgr, :stopped?
    assert_equal mgr.workers.size, seen.size
  end

  def test_quiet_is_idempotent
    mgr = Wurk::Manager.new(@capsule)
    calls = 0
    mgr.workers.each { |w| w.define_singleton_method(:terminate) { calls += 1 } }

    mgr.quiet
    mgr.quiet

    assert_equal mgr.workers.size, calls
  end

  def test_quiet_terminates_the_capsule_fetcher
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    @pool.with { |c| c.call('RPUSH', @public_queue, '{"jid":"halt"}') }

    mgr.quiet

    # Drained fetcher short-circuits retrieve_work even with a job waiting, so a
    # processor can't pull fresh work between quiet and its own terminate.
    assert_nil @capsule.fetcher.retrieve_work
  end

  # `quiet` (manager thread) and `processor_result` (replace-on-die, called from
  # each dying Processor's own thread) both read/mutate @workers. Whichever wins
  # the @plock race is a legitimate outcome — quiet-then-churn skips the
  # replacement (test_processor_result_does_not_replace_after_quiet), churn-then-quiet
  # spawns one first — but neither ordering may raise or corrupt @workers. Looped
  # under this file's parallelize_me! to shake out ordering-dependent bugs.
  def test_quiet_races_processor_churn_without_exceptions_or_leaks
    25.times do
      mgr = Wurk::Manager.new(@capsule)
      silence_processors(mgr)
      victims = mgr.workers.to_a
      errors = Queue.new

      with_processor_new(fake_processor) do
        threads = victims.map do |victim|
          Thread.new do
            mgr.processor_result(victim)
          rescue StandardError => e
            errors << e
          end
        end
        threads << Thread.new do
          mgr.quiet
        rescue StandardError => e
          errors << e
        end
        threads.each(&:join)
      end

      collected = []
      collected << errors.pop until errors.empty?

      assert_empty collected, 'concurrent quiet + processor_result churn must not raise'
      assert_predicate mgr, :stopped?
      assert_operator mgr.workers.size, :<=, @capsule.concurrency, 'no duplicate/leaked worker entries from the race'
    end
  end

  # --- processor_result ------------------------------------------------

  def test_processor_result_removes_processor_and_spawns_replacement
    mgr = Wurk::Manager.new(@capsule)
    victim = mgr.workers.first
    replacement = fake_processor

    with_processor_new(replacement) { mgr.processor_result(victim) }

    refute_includes mgr.workers, victim
    assert_includes mgr.workers, replacement
    assert_equal 3, mgr.workers.size
    assert_predicate replacement, :started?
  end

  def test_processor_result_does_not_replace_after_quiet
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    victim = mgr.workers.first
    mgr.quiet

    mgr.processor_result(victim)

    refute_includes mgr.workers, victim
    assert_equal 2, mgr.workers.size
  end

  def test_processor_result_accepts_reason_argument
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    mgr.quiet
    victim = mgr.workers.first

    # Should not raise — reason is informational only.
    mgr.processor_result(victim, RuntimeError.new('boom'))

    refute_includes mgr.workers, victim
  end

  # A replacement that can't be spawned (Processor.new raising) must escalate
  # through the owner's shutdown request — not silently drop concurrency.
  def test_processor_result_requests_shutdown_when_replacement_cannot_spawn
    requested = 0
    mgr = Wurk::Manager.new(@capsule, shutdown: -> { requested += 1 })
    silence_processors(mgr)
    victim = mgr.workers.first
    reported = capture_error_handler

    boom = ThreadError.new('cannot create thread')
    with_processor_new_raising(boom) { mgr.processor_result(victim) }

    assert_equal 1, requested, 'must ask the owner to shut the process down'
    assert_equal [boom], reported.map(&:first), 'must report via handle_exception'
    refute_includes mgr.workers, victim
    assert_equal 2, mgr.workers.size, 'no silent replacement on failure'
  end

  # Same escalation when the replacement is built but its thread won't start.
  def test_processor_result_requests_shutdown_when_replacement_start_raises
    requested = 0
    mgr = Wurk::Manager.new(@capsule, shutdown: -> { requested += 1 })
    silence_processors(mgr)
    victim = mgr.workers.first

    boom = ThreadError.new('start failed')
    exploding = Object.new.tap { |p| p.define_singleton_method(:start) { raise boom } }
    with_processor_new(exploding) { mgr.processor_result(victim) }

    assert_equal 1, requested
    refute_includes mgr.workers, victim
  end

  # A7: the escalation used to be `Thread.main.raise`, which unwound past #stop
  # (nothing bulk_requeued) and killed the host's main thread when embedded. It
  # must stay a plain call on the dying Processor's own thread.
  def test_processor_result_escalation_does_not_raise_to_the_caller
    mgr = Wurk::Manager.new(@capsule, shutdown: -> {})
    silence_processors(mgr)
    victim = mgr.workers.first

    with_processor_new_raising(ThreadError.new('nope')) do
      assert_nil mgr.processor_result(victim)
    end
  end

  # Sidekiq's `Manager.new(capsule)` arity stays valid (the Sidekiq::Manager
  # alias). With no owner there is no route to take — report and carry on.
  def test_processor_result_without_a_shutdown_route_only_reports
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    victim = mgr.workers.first
    reported = capture_error_handler

    boom = ThreadError.new('cannot create thread')
    with_processor_new_raising(boom) { mgr.processor_result(victim) }

    assert_equal [boom], reported.map(&:first)
  end

  # --- stop / hard_shutdown -------------------------------------------

  def test_stop_short_circuits_when_all_workers_already_drained
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    mgr.workers.clear

    capsule_stopped = false
    @capsule.define_singleton_method(:stop) { capsule_stopped = true }

    mgr.stop(::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 1)

    assert capsule_stopped, 'capsule.stop must run in ensure'
    assert_predicate mgr, :stopped?
  end

  # When wait_for drains the pool before the deadline, stop returns at the
  # second `@workers.empty?` check (line 64 then-branch) and never reaches
  # hard_shutdown.
  def test_stop_returns_after_drain_without_hard_shutdown
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    live = pretend_running(mgr)
    # Simulate workers draining during the poll.
    mgr.define_singleton_method(:wait_for) { |_deadline| @workers.clear }

    hard_shutdown_ran = false
    mgr.define_singleton_method(:hard_shutdown) { hard_shutdown_ran = true }
    @capsule.define_singleton_method(:stop) { nil }

    mgr.stop(::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 5)

    refute hard_shutdown_ran, 'hard_shutdown must be skipped when workers drained'
    assert_empty mgr.workers
  ensure
    live&.kill
  end

  # The workers have to look *running* to reach hard_shutdown: a processor with
  # no thread was never started, and #stop no longer waits on those at all.
  def test_stop_calls_capsule_stop_even_when_hard_shutdown_runs
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    live = pretend_running(mgr)
    mgr.workers.each do |w|
      w.define_singleton_method(:kill) { live.kill }
      w.define_singleton_method(:job) { nil }
    end
    capsule_stopped = false
    @capsule.define_singleton_method(:stop) { capsule_stopped = true }

    mgr.stop(::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - 5)

    assert capsule_stopped
  ensure
    live&.kill
  end

  # A4: a launcher that raises mid-boot rolls back before Manager#start ever
  # ran. Those processors hold no thread, so they never run the callback that
  # removes them from @workers — polling for the Set to empty would burn the
  # whole shutdown deadline inside a web process's after_initialize.
  def test_stop_does_not_wait_out_the_deadline_for_processors_that_never_started
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    @capsule.define_singleton_method(:stop) { nil }
    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

    mgr.stop(started + 10)
    elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 5, "stop waited #{elapsed.round(1)}s on processors that were never started"
  end

  def test_hard_shutdown_bulk_requeues_inflight_jobs_then_kills_threads
    mgr = Wurk::Manager.new(@capsule)
    uow_a = make_uow('payload-a')
    uow_b = make_uow('payload-b')
    workers = mgr.workers.to_a
    workers[0].define_singleton_method(:job) { uow_a }
    workers[1].define_singleton_method(:job) { uow_b }
    workers[2].define_singleton_method(:job) { nil }

    killed = []
    workers.each { |w| w.define_singleton_method(:kill) { killed << self } }

    bulk_requeue_args = nil
    @capsule.fetcher.define_singleton_method(:bulk_requeue) do |jobs|
      bulk_requeue_args = jobs
    end

    mgr.hard_shutdown

    assert_equal [uow_a, uow_b], bulk_requeue_args, 'nil jobs must be compacted out'
    assert_equal workers.sort_by(&:object_id), killed.sort_by(&:object_id)
  end

  def test_hard_shutdown_skips_bulk_requeue_when_no_workers
    mgr = Wurk::Manager.new(@capsule)
    mgr.workers.clear

    called = false
    @capsule.fetcher.define_singleton_method(:bulk_requeue) { |_| called = true }

    mgr.hard_shutdown

    refute called
  end

  # --- compat ---------------------------------------------------------

  def test_pause_time_constant_defined
    assert_includes [0.1, 0.5], Wurk::Manager::PAUSE_TIME
  end

  def test_aliased_under_sidekiq_namespace
    assert_same Wurk::Manager, Sidekiq::Manager
  end

  private

  def private_queue
    Wurk::Fetcher::Reliable.private_queue_name(@public_queue)
  end

  # `fetcher:` is what #acknowledge defers into; a unit without one raises
  # NoMethodError the moment anything ACKs it.
  def make_uow(payload)
    Wurk::Fetcher::Reliable::UnitOfWork.new(queue: @public_queue, job: payload,
                                            config: @capsule, fetcher: @capsule.fetcher)
  end

  # Stand-in for a Processor that satisfies the Manager's interface without
  # spawning a real thread. Records #start so tests can assert wiring. Also
  # answers #terminate as a no-op — a churn race can hand this replacement to
  # `quiet`'s snapshot before it's ever started, and quiet always terminates
  # every worker it captures.
  def fake_processor
    Object.new.tap do |p|
      started = [false]
      p.define_singleton_method(:start)     { started[0] = true }
      p.define_singleton_method(:started?)  { started[0] }
      p.define_singleton_method(:terminate) { nil }
    end
  end

  # No-op terminate on every existing worker so quiet/stop don't try to
  # kill real (un-started) threads.
  def silence_processors(mgr)
    mgr.workers.each { |w| w.define_singleton_method(:terminate) { nil } }
  end

  # #stop only waits on processors that hold a live thread — a never-started
  # one is nothing to drain. Hand every worker the same stand-in so the drain
  # poll behaves as if the manager really booted; returns it for the teardown.
  def pretend_running(mgr)
    live = Thread.new { sleep }
    mgr.workers.each { |w| w.define_singleton_method(:thread) { live } }
    live
  end

  # Minitest 6 dropped minitest/mock; this hand-rolled stub temporarily
  # makes `Wurk::Processor.new` return `value` so we can verify the
  # replace-on-die wiring without spawning real processor threads.
  def with_processor_new(value)
    sc = Wurk::Processor.singleton_class
    original = Wurk::Processor.method(:new)
    sc.define_method(:new) { |*_args, &_blk| value }
    yield
  ensure
    sc.define_method(:new) { |*a, &b| original.call(*a, &b) }
  end

  # Same stub, but `Wurk::Processor.new` raises — simulates OS thread/memory
  # exhaustion during replace-on-die.
  def with_processor_new_raising(error)
    sc = Wurk::Processor.singleton_class
    original = Wurk::Processor.method(:new)
    sc.define_method(:new) { |*_args, &_blk| raise error }
    yield
  ensure
    sc.define_method(:new) { |*a, &b| original.call(*a, &b) }
  end

  # Register a recording error handler and return the array it appends to.
  def capture_error_handler
    seen = []
    @config.error_handlers << ->(ex, ctx, _cfg) { seen << [ex, ctx] }
    seen
  end
end
