# frozen_string_literal: true

require_relative '../test_helper'

# Swarm subclass that hands back fake PIDs instead of forking, so the
# crash-respawn scheduling can be driven without real processes.
class RespawnTestSwarm < Wurk::Swarm
  def initialize(**kwargs)
    super
    @fake_pid = 10_000
  end

  private

  def fork_child(_slot, _idx)
    @fake_pid += 1
  end
end

# Crash-loop respawn wiring of Wurk::Swarm, driven fork-free: fork_child is
# overridden to hand back fake PIDs and the respawn backoff runs off an injected
# clock, so the supervise-thread scheduling (arm on crash → respawn once the
# per-slot backoff window elapses, never sleeping) is asserted deterministically
# without real processes. The real-fork proof lives in the integration layer.
class SwarmRespawnTest < Wurk::Test::UnitCase
  parallelize_me!

  Status = ::Struct.new(:exitstatus)

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
  end

  def test_crashed_child_is_removed_and_armed_for_respawn
    swarm = boot_swarm
    pid, meta = swarm.children.first

    swarm.send(:on_child_exit, pid, Status.new(1))

    refute_includes swarm.children.keys, pid
    assert swarm.instance_variable_get(:@respawn_backoff).pending?(meta[:index]),
           'a crashed slot must be scheduled for respawn'
  end

  def test_respawn_defers_until_backoff_window_elapses
    clock = [1000.0]
    swarm = new_swarm
    inject_respawn_clock(swarm, -> { clock[0] })
    swarm.boot(install_signals: false)
    idx = crash_first_child(swarm)

    swarm.send(:spawn_due_respawns)

    assert_equal 0, slot_count(swarm, idx), 'no respawn while the backoff window is open'

    clock[0] += Wurk::Swarm::RESPAWN_BACKOFF
    swarm.send(:spawn_due_respawns)

    assert_equal 1, slot_count(swarm, idx), 'slot is refilled once the backoff elapses'
  end

  def test_spawn_due_respawns_is_a_noop_while_stopping
    swarm = boot_swarm
    idx = crash_first_child(swarm)
    swarm.instance_variable_set(:@stopping, true)

    swarm.send(:spawn_due_respawns)

    assert_equal 0, slot_count(swarm, idx)
  end

  def test_exit_during_shutdown_is_logged_not_respawned
    swarm = boot_swarm
    swarm.instance_variable_set(:@stopping, true)
    pid, meta = swarm.children.first

    swarm.send(:on_child_exit, pid, Status.new(0))

    refute swarm.instance_variable_get(:@respawn_backoff).pending?(meta[:index]),
           'a clean exit during drain must not schedule a respawn'
  end

  # A fork/resource failure while respawning must neither escape the supervise
  # loop nor drop the pending slot — it stays armed and retries once fork
  # recovers.
  def test_failed_fork_keeps_slot_pending_and_retries
    clock = [1000.0]
    swarm = new_swarm
    inject_respawn_clock(swarm, -> { clock[0] })
    swarm.boot(install_signals: false)
    idx = crash_first_child(swarm)

    fork_ok = [false]
    next_pid = [20_000]
    swarm.define_singleton_method(:fork_child) do |_slot, _index|
      raise Errno::EAGAIN, 'resource temporarily unavailable' unless fork_ok[0]

      next_pid[0] += 1
    end

    clock[0] += Wurk::Swarm::RESPAWN_BACKOFF
    swarm.send(:spawn_due_respawns) # a failed fork must not raise out of supervise

    assert_equal 0, slot_count(swarm, idx), 'a failed fork must not add a child'
    assert swarm.instance_variable_get(:@respawn_backoff).pending?(idx),
           'a failed respawn stays pending for retry instead of being dropped'

    fork_ok[0] = true
    clock[0] += Wurk::Swarm::Backoff::CAP
    swarm.send(:spawn_due_respawns)

    assert_equal 1, slot_count(swarm, idx), 'the slot refills once fork succeeds after backoff'
  end

  private

  def topology
    Wurk::Topology.flat(count: 1, queues: ['default'], concurrency: 1)
  end

  def new_swarm
    RespawnTestSwarm.new(topology: topology, config: @config)
  end

  def boot_swarm
    swarm = new_swarm
    swarm.boot(install_signals: false)
    swarm
  end

  # Kill the slot-0 child and return its slot index.
  def crash_first_child(swarm)
    pid, meta = swarm.children.first
    swarm.send(:on_child_exit, pid, Status.new(1))
    meta[:index]
  end

  def inject_respawn_clock(swarm, clock)
    swarm.instance_variable_set(:@respawn_backoff,
                                Wurk::Swarm::Backoff.new(base: Wurk::Swarm::RESPAWN_BACKOFF, clock: clock))
  end

  def slot_count(swarm, idx)
    swarm.children.count { |_pid, meta| meta[:index] == idx }
  end
end
