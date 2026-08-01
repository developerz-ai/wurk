# frozen_string_literal: true

require_relative '../test_helper'

# Pure-Ruby surface of Wurk::Swarm — initialization, validation, and the
# parts that DON'T fork. The fork-real integration sits in
# test/integration/swarm_boot_test.rb.
class SwarmTest < Wurk::Test::UnitCase
  parallelize_me!

  # Fork-free swarm: `fork_child` hands back a fake PID so `boot` fills
  # `@children` for real without spawning processes.
  class FakeForkSwarm < Wurk::Swarm
    private

    def fork_child(_slot, _idx)
      @fake_pid = (@fake_pid || 9000) + 1
    end
  end

  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
  end

  # --- initialization --------------------------------------------------

  def test_initialize_with_empty_topology
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.new, config: @config)

    assert_empty swarm.children
    assert_kind_of Wurk::Topology, swarm.topology
  end

  def test_initialize_defaults_shutdown_timeout
    swarm = Wurk::Swarm.new(topology: topology, config: @config)

    assert_equal Wurk::Swarm::DEFAULT_SHUTDOWN_TIMEOUT,
                 swarm.instance_variable_get(:@shutdown_timeout)
  end

  def test_initialize_accepts_memory_limit
    swarm = Wurk::Swarm.new(topology: topology, config: @config, memory_limit: 500_000)

    assert_equal 500_000, swarm.instance_variable_get(:@memory_limit)
  end

  # #119: with no explicit memory_limit, the swarm picks up the config's
  # SIDEKIQ_MAXMEM_MB-derived threshold (in KB) so the railtie / wurkswarm /
  # demo entry points all honor it without each passing it through.
  def test_initialize_defaults_memory_limit_from_config
    @config.memory_limit_mb = 750
    swarm = Wurk::Swarm.new(topology: topology, config: @config)

    assert_equal 750 * 1024, swarm.instance_variable_get(:@memory_limit)
  end

  def test_initialize_memory_limit_nil_when_config_unset
    swarm = Wurk::Swarm.new(topology: topology, config: @config)

    assert_nil swarm.instance_variable_get(:@memory_limit)
  end

  # --- boot validation --------------------------------------------------

  def test_boot_raises_on_empty_topology
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.new, config: @config)

    assert_raises(ArgumentError) { swarm.boot(install_signals: false) }
  end

  # --- owner-pid guard --------------------------------------------------

  # A forked child inherits the swarm object *and* the host's `at_exit` hooks —
  # and rails_boot registers `at_exit { swarm.shutdown }` — so ChildBoot's
  # `exit` runs a full drain inside the child, where `@children` lists the
  # child's SIBLINGS. Every supervisory action must no-op off the process that
  # forked them. Real-fork proof: test/integration/swarm_supervision_test.rb.
  def test_shutdown_off_the_owning_process_never_drains
    swarm = non_owner_swarm

    swarm.shutdown(timeout: 0)

    refute swarm.instance_variable_get(:@stopping), 'a non-owner must never start a drain'
    refute_empty swarm.children, 'a non-owner reached hard_kill_stragglers and cleared the fleet'
  end

  # relay_signal, hard_kill_stragglers and the restart machine's `kill:`
  # callback all signal through safe_kill, so that is where the owner check
  # lives. Signal 0 sends nothing but reports delivery — 1 when the kill would
  # have gone out, nil once the guard swallowed it.
  def test_safe_kill_delivers_only_from_the_owning_process
    assert_equal 1, owner_swarm.send(:safe_kill, ::Process.pid, 0)
    assert_nil non_owner_swarm.send(:safe_kill, ::Process.pid, 0)
  end

  # rails_boot's `at_exit` fires on the host's main thread while the supervise
  # thread is reaping / respawning / restarting through the same child table, so
  # the request may only raise a flag — the drain itself belongs to the
  # supervise loop. Real-fork proof that it observes it:
  # test/integration/swarm_supervision_test.rb.
  def test_request_shutdown_never_drains_on_the_calling_thread
    swarm = owner_swarm

    swarm.request_shutdown

    refute swarm.instance_variable_get(:@stopping), 'request_shutdown must not drain inline'
    refute_empty swarm.children, 'the fleet must be left to the supervise thread'
  end

  def test_supervise_returns_at_once_off_the_owning_process
    swarm = non_owner_swarm
    thread = Thread.new { swarm.supervise }
    returned = thread.join(5)
    thread.kill

    assert returned, 'supervise must return immediately off the owning process'
  end

  # --- includes -----------------------------------------------------

  def test_includes_component
    assert_includes Wurk::Swarm.ancestors, Wurk::Component
  end

  # --- constants ---------------------------------------------------------

  def test_default_shutdown_timeout_matches_sidekiq
    assert_equal 25, Wurk::Swarm::DEFAULT_SHUTDOWN_TIMEOUT
  end

  def test_supervisor_tunables_are_numeric # rubocop:disable Minitest/MultipleAssertions
    assert_kind_of Numeric, Wurk::Swarm::SUPERVISE_TICK
    assert_kind_of Numeric, Wurk::Swarm::RESPAWN_BACKOFF
    assert_kind_of Numeric, Wurk::Swarm::HEARTBEAT_WAIT
    assert_kind_of Numeric, Wurk::Swarm::MEMORY_CHECK_INTERVAL
  end

  private

  def topology
    Wurk::Topology.flat(count: 1, queues: ['default'], concurrency: 1)
  end

  def owner_swarm
    swarm = FakeForkSwarm.new(topology: topology, config: @config)
    swarm.boot(install_signals: false)
    swarm
  end

  # A booted swarm exactly as one of its own forked children holds it: the same
  # `@children` map, a different PID.
  def non_owner_swarm
    owner_swarm.tap { |swarm| swarm.instance_variable_set(:@owner_pid, ::Process.pid + 1) }
  end
end
