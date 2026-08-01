# frozen_string_literal: true

require_relative '../test_helper'

# Cross-thread safety of the child table and the restart machine. The supervise
# loop inserts (respawn, rolling restart) and deletes (reap) on every tick while
# other threads walk the same state — rails_boot's at_exit, an embedded host,
# the integration suite — so both live under one reentrant lock. Fork-free:
# fork_child hands back fake PIDs and safe_kill is inert, so the races run
# without real processes or real signals.
class SwarmConcurrencyTest < Wurk::Test::UnitCase
  parallelize_me!

  SLOTS = 4
  CHURN_ROUNDS = 100
  LIVE_CHILDREN = 8
  LOCK_HOLD = 0.2
  JOIN_WAIT = 5

  Status = ::Struct.new(:exitstatus)

  # A restart tick that stays in flight long enough for another thread to try
  # to enqueue behind it.
  class SlowRestart
    def initialize(entered, hold)
      @entered = entered
      @hold = hold
    end

    def advance
      @entered << true
      sleep @hold
    end

    def enqueue(_pids); end
  end

  class ChurnSwarm < Wurk::Swarm
    # Handshake queue. `safe_kill` runs once per step of a child-table walk, so
    # pushing there wakes the churn thread *inside* the iteration rather than
    # leaving it to chance — the insert then lands exactly where an unguarded
    # walk breaks.
    attr_accessor :mid_walk

    def initialize(**kwargs)
      super
      @fake_pid = 40_000
      @pid_lock = ::Mutex.new
    end

    private

    # Both the test thread and the churn thread spawn, so the counter needs its
    # own lock — a collision would hand back a PID already in the table and the
    # insert under test would no longer be a new key.
    def fork_child(_slot, _idx)
      @pid_lock.synchronize { @fake_pid += 1 }
    end

    def safe_kill(_pid, _sig)
      @mid_walk&.push(true)
      ::Thread.pass
    end
  end

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
  end

  # The public reader is handed to callers that iterate it (tests, host
  # introspection) off the supervise thread; the live table would be mutated
  # under them mid-walk.
  def test_children_hands_back_a_snapshot
    swarm = boot_swarm
    snapshot = swarm.children

    swarm.send(:spawn_child, slot(swarm), 0)

    assert_equal SLOTS, snapshot.size, 'children must not alias the live child table'
    assert_equal SLOTS + 1, swarm.children.size
  end

  # TERM/TSTP/USR2 relay walks the table while the supervise thread respawns a
  # crashed slot into it — MRI raises on a Hash gaining a key mid-iteration.
  def test_relay_signal_tolerates_concurrent_spawns
    swarm = boot_swarm

    with_child_churn(swarm) do
      CHURN_ROUNDS.times { swarm.send(:relay_signal, 'TERM') }
    end
  end

  # Same walk, from the tail of a drain — refilled each round because the kill
  # pass clears the table behind it.
  def test_hard_kill_stragglers_tolerates_concurrent_spawns
    swarm = boot_swarm

    with_child_churn(swarm) do
      CHURN_ROUNDS.times do
        LIVE_CHILDREN.times { swarm.send(:spawn_child, slot(swarm), 0) }
        swarm.send(:hard_kill_stragglers)
      end
    end
  end

  # `rolling_restart` runs on whatever thread the USR1 trap or host code calls
  # it from, while the supervise thread is inside `advance` working the same
  # queue and child table. It must wait its turn, not interleave.
  def test_rolling_restart_waits_for_the_supervise_tick
    swarm = boot_swarm
    order = ::Queue.new
    ticker = start_slow_tick(swarm) { order << :supervise }
    restarter = ::Thread.new do
      swarm.rolling_restart
      order << :rolling_restart
    end

    [ticker, restarter].each { |t| t.join(JOIN_WAIT) }
    order.close

    assert_equal %i[supervise rolling_restart], [order.pop, order.pop]
  end

  private

  def topology
    Wurk::Topology.flat(count: SLOTS, queues: ['default'], concurrency: 1)
  end

  def boot_swarm
    swarm = ChurnSwarm.new(topology: topology, config: @config)
    swarm.boot(install_signals: false)
    swarm
  end

  def slot(swarm)
    swarm.topology.assignments.first
  end

  # Spawn/reap the table from a second thread for the duration of the block,
  # each round driven by the walk under test so the insert lands mid-iteration.
  # The insert is what raises when the walk is unguarded, so the churn thread's
  # own failure is the assertion.
  def with_child_churn(swarm)
    gate = ::Queue.new
    failure = []
    swarm.mid_walk = gate
    writer = ::Thread.new { churn(swarm, gate, failure) }
    yield
    swarm.mid_walk = nil
    gate.close
    writer.join(JOIN_WAIT)

    assert_empty failure, "child table was mutated mid-iteration: #{failure.first&.message}"
  ensure
    swarm.mid_walk = nil
    gate&.close
    writer&.kill
  end

  # Blocks on the gate rather than spinning: a hot loop would hold the GVL for a
  # full thread quantum per switch and stretch the test into minutes.
  def churn(swarm, gate, failure)
    live = []
    while gate.pop
      live << swarm.send(:spawn_child, slot(swarm), 0)
      swarm.send(:on_child_exit, live.shift, Status.new(0)) if live.size > LIVE_CHILDREN
    end
  rescue StandardError => e
    failure << e
  end

  # Pin a thread inside a restart tick and return once it is in there.
  def start_slow_tick(swarm)
    entered = ::Queue.new
    swarm.instance_variable_set(:@restart, SlowRestart.new(entered, LOCK_HOLD))
    thread = ::Thread.new do
      swarm.send(:advance_restart)
      yield
    end
    entered.pop(timeout: JOIN_WAIT)
    thread
  end
end
