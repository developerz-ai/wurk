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

  # --- processor_result ------------------------------------------------

  def test_processor_result_removes_processor_and_spawns_replacement # rubocop:disable Minitest/MultipleAssertions
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

  def test_stop_calls_capsule_stop_even_when_hard_shutdown_runs
    mgr = Wurk::Manager.new(@capsule)
    silence_processors(mgr)
    mgr.workers.each do |w|
      w.define_singleton_method(:kill) { nil }
      w.define_singleton_method(:job) { nil }
    end
    capsule_stopped = false
    @capsule.define_singleton_method(:stop) { capsule_stopped = true }

    mgr.stop(::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - 5)

    assert capsule_stopped
  end

  def test_hard_shutdown_bulk_requeues_inflight_jobs_then_kills_threads # rubocop:disable Metrics/AbcSize
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

  def make_uow(payload)
    Wurk::Fetcher::Reliable::UnitOfWork.new(queue: @public_queue, job: payload, config: @capsule)
  end

  # Stand-in for a Processor that satisfies the Manager's interface without
  # spawning a real thread. Records #start so tests can assert wiring.
  def fake_processor
    Object.new.tap do |p|
      started = [false]
      p.define_singleton_method(:start)    { started[0] = true }
      p.define_singleton_method(:started?) { started[0] }
    end
  end

  # No-op terminate on every existing worker so quiet/stop don't try to
  # kill real (un-started) threads.
  def silence_processors(mgr)
    mgr.workers.each { |w| w.define_singleton_method(:terminate) { nil } }
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
end
