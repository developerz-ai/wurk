# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::Manager with a real Capsule + real Reliable fetcher + real
# Redis. Each test owns a unique queue/private list so parallel runs can't
# collide on either Redis state or worker constants. Where possible we avoid
# spawning processor threads — the public surface (workers Set, stopped?,
# processor_result, hard_shutdown wiring) is exercised directly.
# The config[:fetch_class] contract section swaps in a non-subclass stub
# fetcher (PlugInFetcher, no Wurk::Fetcher superclass, no Redis I/O) to pin
# Manager's quiet/hard_shutdown lifecycle against the shape contract alone.
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

    requeued = []
    @capsule.fetcher.define_singleton_method(:bulk_requeue) { |jobs| requeued.concat(jobs) }

    mgr.hard_shutdown

    assert_equal [uow_a, uow_b], requeued, 'nil jobs must be compacted out'
    assert_equal workers.sort_by(&:object_id), killed.sort_by(&:object_id)
  end

  # A job cut short by a deploy runs again from the top; the WARN names each
  # one so a doubled side effect can be traced to its jid.
  def test_hard_shutdown_names_each_interrupted_job
    log = StringIO.new
    @config.logger = ::Logger.new(log)
    mgr = Wurk::Manager.new(@capsule)
    workers = mgr.workers.to_a
    jobs = [make_uow(Wurk.dump_json('class' => 'BillJob', 'jid' => 'j1')),
            make_uow(Wurk.dump_json('class' => 'Sidekiq::ActiveJob::Wrapper', 'wrapped' => 'MailJob', 'jid' => 'j2')),
            make_uow('not json')]
    workers.zip(jobs).each do |w, uow|
      w.define_singleton_method(:job) { uow }
      w.define_singleton_method(:kill) { nil }
    end
    @capsule.fetcher.define_singleton_method(:bulk_requeue) { |_| nil }

    mgr.hard_shutdown

    assert_match(/Interrupting BillJob jid=j1 /, log.string)
    assert_match(/Interrupting MailJob jid=j2 /, log.string)
    assert_match(/Interrupting job queue=/, log.string)
  end

  def test_hard_shutdown_caps_the_per_job_lines
    log = StringIO.new
    @config.logger = ::Logger.new(log)
    @capsule.concurrency = 25
    mgr = Wurk::Manager.new(@capsule)
    mgr.workers.each_with_index do |w, i|
      uow = make_uow(Wurk.dump_json('class' => 'LongJob', 'jid' => "j#{i}"))
      w.define_singleton_method(:job) { uow }
      w.define_singleton_method(:kill) { nil }
    end
    @capsule.fetcher.define_singleton_method(:bulk_requeue) { |_| nil }

    mgr.hard_shutdown

    assert_equal 20, log.string.scan('Interrupting LongJob').size
    assert_includes log.string, 'Interrupting 5 more in-flight jobs'
  end

  # K12: Redis down mid-drain makes bulk_requeue raise. The processors must
  # still be killed — embedded, the host outlives #stop and live threads would
  # keep running jobs over the pools the launcher resets next.
  def test_hard_shutdown_kills_every_processor_even_when_bulk_requeue_raises
    mgr = Wurk::Manager.new(@capsule)
    workers = mgr.workers.to_a
    workers.each { |w| w.define_singleton_method(:job) { nil } }
    killed = []
    workers.each { |w| w.define_singleton_method(:kill) { killed << self } }
    @capsule.fetcher.define_singleton_method(:bulk_requeue) { |_| raise RedisClient::CannotConnectError, 'down' }

    assert_raises(RedisClient::CannotConnectError) { mgr.hard_shutdown }
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

  # --- plug-in fetcher contract (config[:fetch_class]) ------------------

  # The runtime contract (docs/target/sidekiq-free.md:848): a config[:fetch_class]
  # fetcher must respond to initialize(capsule), retrieve_work, bulk_requeue and
  # terminate — Manager drives quiet/hard_shutdown through the capsule's fetcher
  # with no respond_to? guard and no Wurk::Fetcher superclass required.
  # flush_pending_acks is optional: only Processor calls it, behind respond_to?
  # (processor.rb:224). Pinned against a fetcher satisfying the contract by
  # shape, so Manager can't quietly grow a dependency on the base class.
  PlugInFetcher = Class.new do
    attr_reader :capsule, :calls

    def initialize(capsule)
      @capsule = capsule
      @calls = []
    end

    def retrieve_work
      @calls << [:retrieve_work]
      nil
    end

    def bulk_requeue(inprogress)
      @calls << [:bulk_requeue, inprogress]
    end

    def terminate
      @calls << [:terminate]
    end
    # Deliberately no flush_pending_acks: its absence must be invisible to both
    # lifecycle paths (test_plug_in_fetcher_needs_no_flush_pending_acks).
  end

  # The required-method pins: each variant drops one contract method, so a
  # lifecycle driven against it must raise rather than skip the call.
  WithoutTerminateFetcher = Class.new(PlugInFetcher) { undef_method(:terminate) }
  WithoutBulkRequeueFetcher = Class.new(PlugInFetcher) { undef_method(:bulk_requeue) }

  # quiet runs fetcher.terminate then every processor terminate on this thread
  # (manager.rb:73-75), so one shared call stream pins both the exactly-once and
  # the halt-fetch-first order deterministically.
  def test_quiet_terminates_a_plug_in_fetcher_once_before_the_processors
    fetcher = PlugInFetcher.new(@capsule)
    @capsule.fetcher = fetcher
    mgr = Wurk::Manager.new(@capsule)
    mgr.workers.each do |w|
      w.define_singleton_method(:terminate) { fetcher.calls << :processor_terminate }
    end

    mgr.quiet

    refute_kind_of Wurk::Fetcher, fetcher, 'the stub must satisfy the contract by shape, not inheritance'
    assert_same @capsule, fetcher.capsule
    assert_equal [[:terminate]] + Array.new(3, :processor_terminate), fetcher.calls,
                 'fetcher terminate must run exactly once, ahead of every processor'
    assert_predicate mgr, :stopped?
  end

  def test_hard_shutdown_requeues_inflight_jobs_through_a_plug_in_fetcher
    fetcher = PlugInFetcher.new(@capsule)
    @capsule.fetcher = fetcher
    mgr = Wurk::Manager.new(@capsule)
    uow_a = make_uow('payload-a')
    uow_b = make_uow('payload-b')
    workers = mgr.workers.to_a
    workers[0].define_singleton_method(:job) { uow_a }
    workers[1].define_singleton_method(:job) { uow_b }
    workers[2].define_singleton_method(:job) { nil }
    killed = []
    workers.each { |w| w.define_singleton_method(:kill) { killed << self } }

    mgr.hard_shutdown

    assert_equal [[:bulk_requeue, [uow_a, uow_b]]], fetcher.calls,
                 'nil jobs must be compacted out before the plug-in requeue'
    assert_equal workers.sort_by(&:object_id), killed.sort_by(&:object_id)
  end

  # No respond_to? guard: a plug-in fetcher missing a required method fails
  # loudly, mid-lifecycle, instead of the call being skipped into silence.
  def test_quiet_requires_terminate_on_a_plug_in_fetcher
    @capsule.fetcher = WithoutTerminateFetcher.new(@capsule)
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)

    error = assert_raises(NoMethodError) { mgr.quiet }

    assert_match(/terminate/, error.message)
  end

  # Same pin on the hard_shutdown leg — and its ensure must still kill the
  # processors despite the raise (the bulk_requeue-raises contract above).
  def test_hard_shutdown_requires_bulk_requeue_on_a_plug_in_fetcher
    @capsule.fetcher = WithoutBulkRequeueFetcher.new(@capsule)
    mgr = Wurk::Manager.new(@capsule)
    workers = mgr.workers.to_a
    killed = []
    workers.each { |w| w.define_singleton_method(:kill) { killed << self } }

    error = assert_raises(NoMethodError) { mgr.hard_shutdown }

    assert_match(/bulk_requeue/, error.message)
    assert_equal workers.sort_by(&:object_id), killed.sort_by(&:object_id),
                 'the ensure must kill every processor despite the raise'
  end

  # flush_pending_acks stays optional (processor.rb:224's respond_to? guard):
  # a contract fetcher that never defers ACKs defines none, and both lifecycle
  # paths still drive it — terminate on quiet, bulk_requeue([]) on hard_shutdown.
  def test_plug_in_fetcher_needs_no_flush_pending_acks
    fetcher = PlugInFetcher.new(@capsule)
    @capsule.fetcher = fetcher
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)

    refute_respond_to fetcher, :flush_pending_acks

    mgr.quiet
    mgr.hard_shutdown

    assert_includes fetcher.calls, [:terminate]
    assert_includes fetcher.calls, [:bulk_requeue, []]
  end

  # --- hard_shutdown order --------------------------------------------

  # Runs until it is told to stop, then takes its time unwinding, the way a job
  # with an `ensure` of its own does. Each outcome is a way jobs lose the interrupt.
  class UnwindingJob
    include Wurk::Job

    class << self
      attr_accessor :gate
    end

    sidekiq_retry_in do |*|
      gate[:booking] << true
      gate[:release].pop
      60
    end

    def perform(outcome)
      gate[:started] << true
      return if outcome == 'finish'
      raise ArgumentError, 'broke before the interrupt' if outcome == 'fail_first'

      wait_for_interrupt(outcome)
    rescue IOError
      raise unless outcome == 'ensure'
    end

    private

    def gate = self.class.gate

    def wait_for_interrupt(outcome)
      sleep
    rescue Wurk::Shutdown => e
      gate[:unwinding] << true
      gate[:release].pop
      gate[:log] << :unwound
      leave(outcome, e)
    end

    def leave(outcome, interrupt)
      case outcome
      when 'swallow' then nil
      when 'ensure' then raise IOError, 'the cleanup failed'
      when 'nocause' then raise ArgumentError.new('rewritten'), cause: nil
      when 'reschedule' then raise Wurk::Job::Interrupted
      else raise interrupt
      end
    end
  end

  # Swallows what comes out of the job, as an app's catch-all logging does.
  class SwallowingMiddleware
    include Wurk::Middleware::ServerMiddleware

    def call(*)
      yield
    rescue Exception # rubocop:disable Lint/RescueException
      nil
    end
  end

  # Turns it into an error of its own, with nothing left of what caused it.
  class RewritingMiddleware
    include Wurk::Middleware::ServerMiddleware

    def call(*)
      yield
    rescue Wurk::Shutdown
      raise ArgumentError.new('rewritten'), cause: nil
    end
  end

  # Holds a job that has performed in its own middleware.
  class HoldingMiddleware
    include Wurk::Middleware::ServerMiddleware

    def call(*)
      yield
      gate = UnwindingJob.gate
      Thread.handle_interrupt(Wurk::Shutdown => :never) do
        gate[:unwinding] << true
        gate[:release].pop
      end
    end
  end

  # A payload on the public queue is running elsewhere within a millisecond, so
  # it must not be there while its own thread is still in `ensure` blocks: those
  # release what the next run takes (TREASURY-F1P).
  def test_hard_shutdown_requeues_a_job_only_once_its_thread_has_unwound
    mgr = start_unwinding('raise')
    stopper = Thread.new { mgr.hard_shutdown }
    @gate[:unwinding].pop

    assert_equal [0, 1], list_sizes, 'the payload must wait in the private list while its thread unwinds'

    @gate[:release] << true
    stopper.join

    assert_equal [1, 0], list_sizes
    assert_equal [:unwound], @gate[:log]
  end

  # Sent the interrupt before its perform completed, a job is not finished,
  # whatever it makes of it: swallowed, replaced by its own cleanup's error and
  # rescued, rewritten with no cause, turned into an iteration stop. At least once.
  %w[swallow ensure nocause reschedule].each do |outcome|
    define_method("test_hard_shutdown_requeues_a_job_that_loses_the_interrupt_by_#{outcome}") do
      mgr = start_unwinding(outcome)
      interrupt(mgr)

      assert_equal [1, 0], list_sizes
    end
  end

  # What it was interrupted into booked nothing: one copy, not a retry beside it.
  def test_hard_shutdown_books_no_retry_for_an_error_the_interrupt_caused
    mgr = start_unwinding('nocause', retries: 5)
    interrupt(mgr)

    assert_equal [1, 0], list_sizes
    assert_equal 0, booked(Wurk::Keys::RETRY)
  end

  def test_hard_shutdown_kills_no_job_for_an_error_the_interrupt_caused
    died = []
    @config.death_handlers << ->(job, _error) { died << job['jid'] }
    mgr = start_unwinding('nocause')
    interrupt(mgr)

    assert_equal [1, 0], list_sizes
    assert_empty died
  end

  def test_hard_shutdown_requeues_a_job_whose_middleware_swallows_the_interrupt
    @capsule.config.server_middleware.add(SwallowingMiddleware)
    mgr = start_unwinding('raise')
    interrupt(mgr)

    assert_equal [1, 0], list_sizes
  end

  def test_hard_shutdown_books_no_retry_for_what_middleware_makes_of_the_interrupt
    @capsule.config.server_middleware.add(RewritingMiddleware)
    mgr = start_unwinding('raise', retries: 5)
    interrupt(mgr)

    assert_equal [1, 0], list_sizes
    assert_equal 0, booked(Wurk::Keys::RETRY)
  end

  # The thread's last job completing says nothing about this one.
  def test_hard_shutdown_requeues_a_swallowed_interrupt_after_a_finished_job
    mgr = start_unwinding('finish', 'swallow', concurrency: 1)
    interrupt(mgr)

    assert_equal [1, 0], list_sizes
  end

  # Finished before the interrupt was sent: its middleware is all that is left,
  # and running it again would repeat it.
  def test_hard_shutdown_does_not_requeue_a_job_that_had_finished
    @capsule.config.server_middleware.add(HoldingMiddleware)
    mgr = start_unwinding('finish')
    @gate[:unwinding].pop
    stopper = Thread.new { mgr.hard_shutdown }
    wait_until { mgr.workers.all? { |w| w.instance_variable_get(:@interrupted) } }
    @gate[:release] << true
    stopper.join

    assert_equal [0, 0], list_sizes
  end

  # Failed and its retry booked before the interrupt was sent: the retry is the
  # job's next run. Held where the failure is reported, which is after the booking.
  def test_hard_shutdown_does_not_requeue_a_job_whose_retry_is_booked
    mgr = start_unwinding('fail_first', retries: 5)
    @gate[:release] << true
    @gate[:reported].pop
    stopper = Thread.new { mgr.hard_shutdown }
    wait_until { mgr.workers.all? { |w| w.instance_variable_get(:@interrupted) } }
    @gate[:report_release] << true
    stopper.join

    assert_equal [0, 0], list_sizes
    assert_equal 1, booked(Wurk::Keys::RETRY)
  end

  # The same, held on its way out of the dispatch.
  def test_hard_shutdown_does_not_requeue_a_job_leaving_with_its_retry_booked
    gate = nil
    @config[:reloader] = proc do |&job|
      job.call
    ensure
      gate[:reported] << true
      gate[:report_release].pop
    end
    mgr = start_unwinding('fail_first', retries: 5) { |made| gate = made }
    @gate[:release] << true
    @gate[:reported].pop
    stopper = Thread.new { mgr.hard_shutdown }
    wait_until { mgr.workers.all? { |w| w.instance_variable_get(:@interrupted) } }
    2.times { @gate[:report_release] << true }
    stopper.join

    assert_equal [0, 0], list_sizes
    assert_equal 1, booked(Wurk::Keys::RETRY)
  end

  # Sent while the retry is being booked, the interrupt can cut that short: the
  # job goes back to its queue or into the retry set, never neither.
  def test_hard_shutdown_keeps_a_job_that_was_booking_its_retry
    mgr = start_unwinding('fail_first', retries: 5)
    @gate[:report_release] << true
    @gate[:booking].pop
    stopper = Thread.new { mgr.hard_shutdown }
    wait_until { mgr.workers.all? { |w| w.instance_variable_get(:@interrupted) } }
    @gate[:release] << true
    stopper.join

    assert_equal 1, list_sizes.sum + booked(Wurk::Keys::RETRY)
  end

  # One slow thread must not hold up the rest of the capsule: each job goes back
  # as its own thread ends.
  def test_hard_shutdown_requeues_each_job_as_its_own_thread_ends
    mgr = start_unwinding('raise', 'raise')
    stopper = Thread.new { mgr.hard_shutdown }
    2.times { @gate[:unwinding].pop }
    @gate[:release] << true
    wait_until(1) { list_sizes == [1, 1] }

    assert_equal [:unwound], @gate[:log], 'the second thread was meant to be still unwinding'

    @gate[:release] << true
    stopper.join

    assert_equal [2, 0], list_sizes
  end

  # A requeue Redis refuses as a thread ends is tried again with the rest.
  def test_hard_shutdown_retries_a_refused_requeue
    mgr = start_unwinding('raise')
    real = @capsule.fetcher.method(:bulk_requeue)
    refusals = [RedisClient::CannotConnectError.new('down')]
    @capsule.fetcher.define_singleton_method(:bulk_requeue) do |jobs|
      raise refusals.pop if refusals.any? && jobs.any?

      real.call(jobs)
    end
    interrupt(mgr)

    assert_empty refusals
    assert_equal [1, 0], list_sizes
  end

  # The wait and the stragglers' window must end before the Launcher stops
  # waiting for this Manager and tears Redis down under it.
  def test_hard_shutdown_fits_the_launchers_budget
    total = Wurk::Manager::UNWIND_GRACE + Wurk::Manager::STRAGGLER_GRACE

    assert_operator total, :<, Wurk::Launcher::TEARDOWN_GRACE
    assert_operator total, :<, Wurk::TimerLoop::JOIN_TIMEOUT
    assert_operator total, :<, Wurk::Swarm::SHUTDOWN_GRACE
  end

  # A thread that will not unwind holds up the requeue only so long: its payload
  # goes back while it still runs, as one past saving.
  def test_hard_shutdown_requeues_a_job_whose_thread_never_unwinds
    mgr = start_unwinding('raise')
    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    mgr.hard_shutdown
    elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started

    assert_equal [1, 0], list_sizes
    assert_empty @gate[:log], 'the thread was meant to be still unwinding'
    assert_operator elapsed, :<, 4, 'hard_shutdown must stay inside the launcher\'s join budget'
  ensure
    @gate[:release] << true
  end

  # The wait is interruptible (an embedded host's own timeout around #stop), and
  # the payload must go back all the same.
  def test_hard_shutdown_requeues_even_when_its_wait_is_interrupted
    mgr = start_unwinding('raise')
    stopper = Thread.new do
      mgr.hard_shutdown
    rescue RuntimeError
      nil
    end
    @gate[:unwinding].pop
    stopper.raise 'host timeout'
    stopper.join

    assert_equal [1, 0], list_sizes
  ensure
    @gate[:release] << true
  end

  # Without a private list nothing holds the payload while a thread unwinds, so a
  # SIGKILL in the wait would lose it: a fetcher of its own requeues first.
  def test_hard_shutdown_requeues_a_plug_in_fetchers_jobs_before_killing
    fetcher = PlugInFetcher.new(@capsule)
    @capsule.fetcher = fetcher
    mgr = Wurk::Manager.new(@capsule)
    mgr.workers.each do |w|
      w.define_singleton_method(:job) { nil }
      w.define_singleton_method(:kill) { fetcher.calls << :kill }
    end

    mgr.hard_shutdown

    assert_equal [[:bulk_requeue, []], :kill, :kill, :kill], fetcher.calls
  end

  # --- watchdog lifecycle ----------------------------------------------

  # The capsule's per-job watchdog is released by #stop, not #quiet: a quieted
  # capsule still has in-flight jobs, and a bound shorter than the drain budget
  # has to fire before shutdown wins.
  def test_quiet_leaves_the_capsule_watchdog_running
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    terminated = watchdog_terminations

    mgr.quiet

    assert_equal 0, terminated.size
  end

  def test_stop_terminates_the_capsule_watchdog
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    mgr.workers.clear
    terminated = watchdog_terminations
    @capsule.define_singleton_method(:stop) { nil }

    mgr.stop(::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 1)

    assert_equal 1, terminated.size
  end

  # Stop can land on a capsule that never reached prepare! (a launcher that
  # raised mid-boot), so the terminate has to tolerate no watchdog at all.
  def test_stop_tolerates_a_capsule_without_a_watchdog
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    mgr.workers.clear

    assert_nil @capsule.watchdog

    mgr.stop(::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 1)

    assert_predicate mgr, :stopped?
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

  # A started Manager with one worker inside UnwindingJob#perform per outcome.
  def start_unwinding(*outcomes, retries: false, concurrency: outcomes.size)
    @gate = { started: Queue.new, unwinding: Queue.new, booking: Queue.new, release: Queue.new, log: [],
              reported: Queue.new, report_release: Queue.new }
    UnwindingJob.gate = gate = @gate
    yield gate if block_given?
    @config.error_handlers.replace([lambda do |error, context, *|
      next unless context[:context] == 'Job raised exception' && error.message.start_with?('broke before')

      gate[:reported] << true
      gate[:report_release].pop
    end])
    @capsule.concurrency = concurrency
    mgr = Wurk::Manager.new(@capsule)
    payloads = outcomes.each_with_index.map do |outcome, i|
      Wurk.dump_json('class' => UnwindingJob.name, 'jid' => "#{jid_prefix}#{i}", 'queue' => @queue_name,
                     'args' => [outcome], 'retry' => retries)
    end
    @pool.with { |c| c.call('LPUSH', @public_queue, *payloads) }
    mgr.start
    outcomes.size.times { @gate[:started].pop }
    mgr.quiet
    mgr
  end

  def jid_prefix = "u-#{object_id}-"

  # hard_shutdown, with every job let go as soon as it unwinds.
  def interrupt(mgr)
    @capsule.concurrency.times { @gate[:release] << true }
    mgr.hard_shutdown
  end

  # How many of this test's jobs are in the sorted set. Jobs are pushed by raw
  # payload, so the set is shared with other tests only by key.
  def booked(set)
    @pool.with { |c| c.call('ZRANGE', set, 0, -1) }.count { |raw| raw.include?(jid_prefix) }
  end

  def wait_until(seconds = 5)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + seconds
    until yield
      flunk 'condition not met in time' if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
  end

  # [public, private]
  def list_sizes
    @pool.with { |c| [c.call('LLEN', @public_queue), c.call('LLEN', private_queue)] }
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

  # Materializes the capsule's watchdog (prepare! is what a real boot runs) and
  # records each #terminate; returns the recorder.
  def watchdog_terminations
    @capsule.prepare!
    [].tap do |seen|
      @capsule.watchdog.define_singleton_method(:terminate) { seen << :terminated }
    end
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
