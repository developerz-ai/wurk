# frozen_string_literal: true

require_relative '../test_helper'

# Which PIDs the supervisor may wait on, and what it must never leave behind.
# Both halves only bite when the supervisor shares a process with a host app
# (`RailsBoot.boot_swarm` runs the supervise loop on a background thread of the
# web process): a wildcard `wait2(-1)` steals the host's own subprocess exit
# statuses, and a SIGKILLed straggler nobody waits on stays a zombie for the
# life of a host that outlives the swarm.
#
# Fork-free — `fork_child` hands back fake PIDs and `Process.wait2` is stubbed —
# so the wiring is asserted deterministically. Real-fork proof:
# test/integration/swarm_supervision_test.rb.
class SwarmReapingTest < Wurk::Test::UnitCase
  parallelize_me!

  SLOTS = 3

  Status = ::Struct.new(:exitstatus)

  # Fake PIDs, so kills are recorded rather than delivered: 40_001 may well name
  # a real, unrelated process on this box.
  class ReapTestSwarm < Wurk::Swarm
    attr_reader :killed

    def initialize(**kwargs)
      super
      @fake_pid = 40_000
      @killed = []
    end

    private

    def fork_child(_slot, _idx)
      @fake_pid += 1
    end

    def safe_kill(pid, sig)
      @killed << [pid, sig]
    end
  end

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
  end

  # --- reap only what the swarm forked -----------------------------------

  def test_reap_children_waits_only_on_pids_the_swarm_forked
    swarm = boot_swarm
    waited = []

    with_stubbed_wait2(still_running(waited)) { swarm.send(:reap_children) }

    assert_equal swarm.children.keys.sort, waited.sort,
                 'the supervisor must wait on its own children by pid, never on -1'
  end

  # The per-pid wait still has to feed the crash-respawn scheduler the exit it
  # observed — the wildcard form used to be what delivered the pid.
  def test_reap_children_routes_an_observed_exit_to_the_respawn_scheduler
    swarm = boot_swarm
    dead, meta = swarm.children.first

    with_stubbed_wait2(exits(dead, 9)) { swarm.send(:reap_children) }

    refute_includes swarm.children.keys, dead
    assert respawn_pending?(swarm, meta[:index]), 'an observed crash must arm the slot for respawn'
  end

  # ECHILD on a pid the swarm forked means someone else already reaped it — an
  # embedded host running its own wildcard reaper is the exact mirror of the bug
  # this suite pins. Skipping it would wedge the slot forever: never respawned
  # (it still looks alive), never reaped (there is nothing left to reap).
  def test_reap_children_retires_a_slot_another_reaper_already_took
    swarm = boot_swarm
    stolen, meta = swarm.children.first

    with_stubbed_wait2(echild_for(stolen)) { swarm.send(:reap_children) }

    refute_includes swarm.children.keys, stolen, 'a pid reaped elsewhere must not stay in the child table'
    assert respawn_pending?(swarm, meta[:index]), 'the slot it held must be refilled'
  end

  # --- leave no zombie behind ---------------------------------------------

  def test_hard_kill_stragglers_reaps_what_it_killed_before_forgetting
    swarm = boot_swarm
    stragglers = swarm.children.keys
    waited = []

    with_stubbed_wait2(reaps_everything(waited)) { swarm.send(:hard_kill_stragglers) }

    assert_equal stragglers.sort, swarm.killed.map(&:first).sort
    assert_equal stragglers.sort, waited.sort, 'a SIGKILLed straggler left unwaited stays a zombie'
    assert_empty swarm.children
  end

  # SIGKILL is asynchronous, so the sweep retries — but a pid wedged in
  # uninterruptible sleep must not hold the drain open. The budget is spent and
  # the table cleared regardless.
  def test_hard_kill_stragglers_gives_up_on_a_pid_that_never_reaps
    swarm = boot_swarm
    attempts = 0
    never_reaps = lambda do |_pid, _flags|
      attempts += 1
      nil
    end

    with_stubbed_wait2(never_reaps) { swarm.send(:hard_kill_stragglers) }

    assert_equal SLOTS * Wurk::Swarm::HARD_KILL_REAP_ATTEMPTS, attempts, 'the sweep must be bounded'
    assert_empty swarm.children, 'an unreapable straggler must still be forgotten'
  end

  private

  def topology
    Wurk::Topology.flat(count: SLOTS, queues: ['default'], concurrency: 1)
  end

  def boot_swarm
    swarm = ReapTestSwarm.new(topology: topology, config: @config)
    swarm.boot(install_signals: false)
    swarm
  end

  def respawn_pending?(swarm, idx)
    swarm.instance_variable_get(:@respawn_backoff).pending?(idx)
  end

  # --- Process.wait2 stand-ins (pid, flags) -> nil | [pid, status] ---------

  def still_running(log)
    lambda do |pid, _flags|
      log << pid
      nil
    end
  end

  def exits(dead, code)
    ->(pid, _flags) { pid == dead ? [pid, Status.new(code)] : nil }
  end

  def echild_for(stolen)
    lambda do |pid, _flags|
      raise Errno::ECHILD if pid == stolen

      nil
    end
  end

  def reaps_everything(log)
    lambda do |pid, _flags|
      log << pid
      [pid, Status.new(nil)]
    end
  end

  # Minitest 6 dropped minitest/mock; this hand-rolled stub swaps Process.wait2
  # for `replacement`, mirroring swarm_test.rb's fork stub. `parallelize_me!` is
  # a no-op (test_helper.rb), so this class's tests run serially in their own
  # forked worker and nothing else in the process waits while it is installed.
  def with_stubbed_wait2(replacement)
    sc = ::Process.singleton_class
    original = ::Process.method(:wait2)
    sc.define_method(:wait2) { |*args| replacement.call(*args) }
    yield
  ensure
    sc.define_method(:wait2) { |*a| original.call(*a) }
  end
end
