# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::Swarm::OrphanGuard drives orphan detection for swarm children. Unit
# level: pdeathsig is kept off and the drain action is injected, so nothing
# actually signals the test process. The real fork + PR_SET_PDEATHSIG proof
# lives in the integration layer.
class SwarmOrphanGuardTest < Wurk::Test::UnitCase
  parallelize_me!

  # Forces the libc/prctl path to blow up so the rescue in #set_pdeathsig is
  # exercised without depending on the platform (minitest/mock is gone in
  # Minitest 6, so subclass rather than stub).
  class ExplodingGuard < Wurk::Swarm::OrphanGuard
    def arm_pdeathsig
      raise 'no libc'
    end
  end

  def setup
    super
    @logger = ::Logger.new(IO::NULL)
    @threads = []
  end

  def teardown
    @threads.each { |t| t.kill if t.alive? }
  ensure
    super
  end

  # --- orphaned? ---------------------------------------------------------

  def test_not_orphaned_while_parent_matches
    guard = build(::Process.ppid)

    refute_predicate guard, :orphaned?
  end

  def test_orphaned_once_parent_pid_no_longer_matches
    guard = build(-1) # never our real parent → always "reparented"

    assert_predicate guard, :orphaned?
  end

  # --- watchdog ----------------------------------------------------------

  def test_watchdog_drains_when_orphaned
    fired = ::Queue.new
    guard = build(-1, on_orphan: -> { fired << true })

    thread = track(guard.arm)
    thread.join(2)

    refute_predicate thread, :alive?, 'watchdog should exit after draining'
    assert_equal 1, fired.size, 'an orphaned child must drain exactly once'
  end

  def test_watchdog_stays_quiet_while_supervised
    fired = ::Queue.new
    guard = build(::Process.ppid, on_orphan: -> { fired << true })

    thread = track(guard.arm)
    sleep 0.1 # several 0.02s watchdog ticks

    assert_predicate thread, :alive?, 'watchdog must keep polling while the parent lives'
    assert_empty fired, 'a supervised child must never self-drain'
  end

  def test_arm_returns_the_watchdog_thread
    thread = track(build(::Process.ppid).arm)

    assert_kind_of ::Thread, thread
  end

  def test_drain_swallows_a_failing_on_orphan_callback
    guard = build(-1, on_orphan: -> { raise 'boom' })

    thread = track(guard.arm)
    thread.join(2)

    refute_predicate thread, :alive?, 'a raising drain callback must not wedge the watchdog thread'
  end

  # --- pdeathsig ---------------------------------------------------------

  def test_pdeathsig_defaults_to_platform_support
    # No explicit pdeathsig: → the default arg evaluates the platform probe.
    guard = Wurk::Swarm::OrphanGuard.new(::Process.ppid, logger: @logger)

    assert_equal Wurk::Swarm::OrphanGuard.pdeathsig_supported?,
                 guard.instance_variable_get(:@pdeathsig)
  end

  def test_pdeathsig_disabled_is_a_noop
    guard = Wurk::Swarm::OrphanGuard.new(::Process.ppid, logger: @logger, pdeathsig: false)

    assert_nil guard.send(:set_pdeathsig), 'disabled pdeathsig must not touch the process'
  end

  def test_pdeathsig_failure_is_swallowed
    guard = ExplodingGuard.new(::Process.ppid, logger: @logger, pdeathsig: true)

    guard.send(:set_pdeathsig) # arm_pdeathsig raises → the rescue must swallow it

    pass 'a prctl failure must be swallowed, not raised'
  end

  def test_arm_pdeathsig_sets_parent_death_signal_on_linux
    skip 'PR_SET_PDEATHSIG is Linux-only' unless Wurk::Swarm::OrphanGuard.pdeathsig_supported?

    guard = Wurk::Swarm::OrphanGuard.new(::Process.ppid, logger: @logger, pdeathsig: true)
    begin
      guard.send(:arm_pdeathsig) # real prctl — must return without raising
    ensure
      clear_pdeathsig
    end
  end

  private

  def build(parent_pid, on_orphan: nil)
    Wurk::Swarm::OrphanGuard.new(
      parent_pid, logger: @logger, interval: 0.02, pdeathsig: false, on_orphan: on_orphan
    )
  end

  def track(thread)
    @threads << thread
    thread
  end

  # Reset PR_SET_PDEATHSIG to 0 so a test worker that armed it for real can't
  # be TERMed later if its parent exits first.
  def clear_pdeathsig
    require 'fiddle'
    libc = ::Fiddle.dlopen(nil)
    ::Fiddle::Function.new(
      libc['prctl'], [::Fiddle::TYPE_INT, ::Fiddle::TYPE_LONG, ::Fiddle::TYPE_LONG,
                      ::Fiddle::TYPE_LONG, ::Fiddle::TYPE_LONG], ::Fiddle::TYPE_INT
    ).call(Wurk::Swarm::OrphanGuard::PR_SET_PDEATHSIG, 0, 0, 0, 0)
  rescue StandardError
    nil
  end
end
