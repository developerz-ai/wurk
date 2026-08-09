# frozen_string_literal: true

require_relative '../test_helper'

# Pins Wurk::Watchdog, the single monotonic timer thread that cuts jobs which
# outlive a bound. Three properties carry the design: no bound armed → no
# thread; one thread serves every bounded job in the capsule; and a fired raise
# is delivered inside the block it guards, never after it — the stdlib `Timeout`
# failure mode this class exists to avoid.
class WatchdogTest < Wurk::Test::UnitCase
  parallelize_me!

  class Bound < StandardError; end

  # A second class, because the two masks in #watch are per-exception: only a
  # bound of a *different* class can be delivered inside another one's scope.
  class Other < StandardError; end

  # Models a host handing us an exception class that can't be built. Thread#raise
  # instantiates in the *calling* thread, so this blows up in the scanner.
  Unbuildable = Class.new(StandardError) do
    def self.exception(*)
      raise 'cannot build'
    end
  end

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @capsule = Wurk::Capsule.new("wd-#{Process.pid}-#{object_id}", @config)
    @watchdogs = []
  end

  def teardown
    @watchdogs.each(&:terminate)
  ensure
    super
  end

  # --- zero cost when nothing is bounded --------------------------------

  def test_construction_spawns_no_thread
    wd = build

    refute_predicate wd, :running?
    assert_equal 0, wd.size
    assert_empty scanners, 'an unconfigured capsule must carry no scanner thread'
  end

  def test_terminate_without_a_bound_is_a_noop
    wd = build

    wd.terminate

    refute_predicate wd, :running?
  end

  # --- bound met --------------------------------------------------------

  def test_returns_the_block_value_and_retracts_the_bound
    wd = build

    assert_equal :ok, wd.watch(5, Bound) { :ok }
    assert_equal 0, wd.size
  end

  def test_a_block_that_raises_its_own_error_still_retracts_the_bound
    wd = build

    assert_raises(ArgumentError) { wd.watch(5, Bound) { raise ArgumentError } }
    assert_equal 0, wd.size
  end

  def test_completion_inside_the_bound_leaves_no_pending_interrupt
    wd = build(interval: 0.01)

    wd.watch(5, Bound) { sleep 0.05 }

    refute_predicate Thread, :pending_interrupt?
  end

  # --- bound exceeded ---------------------------------------------------

  def test_bound_exceeded_raises_the_callers_exception_and_message
    wd = build(interval: 0.01)

    err = assert_raises(Bound) { wd.watch(0.02, Bound, 'execution expired') { sleep 5 } }

    assert_equal 'execution expired', err.message
    assert_equal 0, wd.size
  end

  def test_bound_exceeded_without_a_message_carries_the_class_name
    wd = build(interval: 0.01)

    err = assert_raises(Bound) { wd.watch(0, Bound) { sleep 5 } }

    assert_equal Bound.name, err.message
  end

  # --- containment (the stdlib Timeout failure mode) --------------------

  # A raise that wins the race against retraction must be delivered where #watch
  # is still on the stack — not at whatever checkpoint the thread reaches next,
  # which inside a Processor is the ACK, or the next job. Widening #disarm makes
  # that race deterministic: the bound passes while the thread sits in the
  # masked retraction.
  def test_a_raise_racing_the_retraction_lands_inside_watch
    wd = build(interval: 0.01)
    retracted = false
    wd.define_singleton_method(:disarm) do |id|
      sleep 0.1
      super(id)
      retracted = true
    end

    assert_raises(Bound) { wd.watch(0.02, Bound) { :done } }

    assert retracted, 'the raise must not land inside the masked retraction'
    refute_predicate Thread, :pending_interrupt?, 'no interrupt may outlive #watch'
    assert_equal 0, wd.size
  end

  # The other half of the same race, and the one the mask alone cannot close:
  # the scan has already selected the entry and is about to raise when the
  # thread it aimed at finishes. Selection and raise are one critical section
  # under @lock, and #disarm takes that lock, so the thread is parked inside its
  # mask — not past it — when the exception goes out.
  def test_a_raise_already_selected_cannot_overtake_the_retraction
    wd = build(interval: 60)
    poised, release = poise_the_scan(wd)
    finish = Queue.new
    left_block = Queue.new
    outcome = Queue.new
    worker = bounded_worker(wd, finish, left_block, outcome)
    wait_until { wd.size == 1 }
    scan = Thread.new { wd.send(:tick) }

    poised.pop(timeout: 5)      # entry selected, raise not issued yet
    finish << :go               # the guarded block returns at exactly that moment
    left_block.pop(timeout: 5)
    wait_until { worker.status == 'sleep' || !worker.status }
    release << :go              # and only now does the raise go out

    assert_equal :contained, outcome.pop(timeout: 5), 'the raise landed outside #watch'
    assert_equal :clean, outcome.pop(timeout: 5), 'no interrupt may outlive #watch'
  ensure
    release&.<<(:go)
    scan&.join(2)
    worker&.join(2)
  end

  # Two bounds on one thread: the inner retraction runs inside the outer bound's
  # `:immediate` scope, so an outer raise landing mid-retraction would strand the
  # inner entry — still armed, no thread left to retract it, free to fire into
  # whatever that thread picks up next. Widening #disarm makes the race
  # deterministic: the outer bound passes while the inner one is retracting.
  def test_an_outer_bound_firing_mid_retraction_strands_nothing
    wd = build(interval: 0.01)
    inner_id = nil
    wd.define_singleton_method(:disarm) do |id|
      sleep 0.3 if id == inner_id
      super(id)
    end

    assert_raises(Other) do
      wd.watch(0.02, Other, 'outer') do
        wd.watch(5, Bound, 'inner') { inner_id = wd.instance_variable_get(:@seq) }
      end
    end

    assert_equal 0, wd.size, 'the inner bound must be retracted, not stranded'
  end

  def test_nested_bounds_fire_independently
    wd = build(interval: 0.01)
    inner = nil

    wd.watch(5, Bound, 'outer') do
      wd.watch(0.02, Bound, 'inner') { sleep 5 }
    rescue Bound => e
      inner = e.message
    end

    assert_equal 'inner', inner
    assert_equal 0, wd.size
  end

  # --- one thread, many bounds ------------------------------------------

  # Every spawn attempt has run once four bounds are armed — #arm spawns under
  # the same lock it registers under. Only the *name* trails: safe_thread sets
  # it from inside the thread, so `scanners` is empty until the scanner is first
  # scheduled, and the size check above can be satisfied on its first poll
  # without ever yielding the GVL. Wait for the name rather than racing it.
  def test_one_scanner_serves_every_bounded_thread
    wd = build
    gate = Queue.new
    threads = Array.new(4) { Thread.new { wd.watch(5, Bound) { gate.pop } } }
    wait_until { wd.size == 4 }
    wait_until { scanners.any? }

    assert_equal 1, scanners.size
  ensure
    4.times { gate << :go }
    threads&.each { |t| t.join(2) }
  end

  # safe_thread names the thread from inside it, so the name appears a beat
  # after #watch returns — wait for it rather than racing it.
  def test_the_scanner_is_named_for_the_logs
    wd = build
    wd.watch(5, Bound) { :ok }

    assert_predicate wd, :running?
    wait_until { scanners.size == 1 }

    assert_same wd.instance_variable_get(:@thread), scanners.first
  end

  def test_repeated_bounds_leak_neither_entries_nor_threads
    wd = build

    200.times { wd.watch(5, Bound) { nil } }
    wait_until { scanners.size == 1 }

    assert_equal 0, wd.size
    assert_equal [wd.instance_variable_get(:@thread)], scanners
  end

  # --- stranded entries -------------------------------------------------

  # A bound armed by a thread that then died (killed mid-drain) is retracted by
  # the scan, and the raise into the corpse costs nothing — an Unbuildable that
  # was never built proves Thread#raise short-circuits on a dead target, which is
  # why no liveness check guards it.
  def test_a_bound_whose_thread_died_is_dropped_without_raising
    wd = build(interval: 60)
    reported = capture_errors
    dead = Thread.new { wd.send(:arm, 0, Unbuildable, nil) }
    dead.join

    assert_equal 1, wd.size
    wd.send(:tick)

    assert_equal 0, wd.size
    assert_empty reported
  end

  def test_an_exception_class_that_cannot_be_built_is_reported_not_fatal
    wd = build(interval: 60)
    reported = capture_errors
    wd.send(:arm, 0, Unbuildable, nil)

    wd.send(:tick)

    assert_equal 0, wd.size
    assert_equal 1, reported.size
    ex, ctx = reported.first

    assert_equal 'cannot build', ex.message
    assert_equal Wurk::Watchdog::THREAD_NAME, ctx[:context]
    assert_predicate wd, :running?
  end

  # --- lifecycle --------------------------------------------------------

  def test_terminate_stops_the_scanner
    wd = build(interval: 0.01)
    wd.watch(5, Bound) { :ok }

    assert_predicate wd, :running?

    wd.terminate

    refute_predicate wd, :running?
  end

  def test_terminate_is_idempotent
    wd = build(interval: 0.01)
    wd.watch(5, Bound) { :ok }

    wd.terminate
    wd.terminate

    refute_predicate wd, :running?
  end

  # An embedded host that boots again reuses the capsule, and therefore this
  # object: the next bound must get a scanner that ticks, not one that sees the
  # stale done flag and exits at once.
  def test_a_bound_armed_after_terminate_still_fires
    wd = build(interval: 0.01)
    wd.watch(5, Bound) { :ok }
    wd.terminate

    assert_raises(Bound) { wd.watch(0.02, Bound) { sleep 5 } }
    assert_predicate wd, :running?
  end

  # safe_thread reports and re-raises, so an unhandled error inside a scan kills
  # the thread. The capsule must not stay unguarded for the life of the process.
  def test_a_dead_scanner_is_replaced_by_the_next_bound
    wd = build(interval: 0.01)
    wd.watch(5, Bound) { :ok }
    scanner = wd.instance_variable_get(:@thread)
    scanner.kill
    scanner.join(2)

    assert_raises(Bound) { wd.watch(0.02, Bound) { sleep 5 } }
    refute_same scanner, wd.instance_variable_get(:@thread)
  end

  private

  # Parks the scan between selecting a due entry and raising into it — the exact
  # interleaving the lock exists to forbid. Returns the two gates: one that fires
  # when the scan is poised, one that lets it through.
  def poise_the_scan(watchdog)
    poised = Queue.new
    release = Queue.new
    watchdog.define_singleton_method(:interrupt) do |entry, failures|
      poised << :selected
      release.pop
      super(entry, failures)
    end
    [poised, release]
  end

  # A thread holding a bound that has already passed, blocked inside the guarded
  # block until `finish`. Reports where the raise landed — inside #watch or after
  # it — and whether anything was still pending once #watch returned.
  def bounded_worker(watchdog, finish, left_block, outcome)
    Thread.new do
      landed = begin
        watchdog.watch(0, Bound) do
          finish.pop
          left_block << :returning
        end
        :escaped
      rescue Bound
        :contained
      end
      outcome << landed
      outcome << (Thread.pending_interrupt? ? :pending : :clean)
    end
  end

  def build(interval: Wurk::Watchdog::SCAN_INTERVAL)
    Wurk::Watchdog.new(@capsule, interval: interval).tap { |wd| @watchdogs << wd }
  end

  def scanners
    Thread.list.select { |t| t.name == Wurk::Watchdog::THREAD_NAME }
  end

  def capture_errors
    [].tap { |seen| @config.error_handlers << ->(ex, ctx, _cfg) { seen << [ex, ctx] } }
  end

  def wait_until(timeout: 3)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    sleep 0.005 until yield || ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

    assert yield, 'condition never became true'
  end
end
