# frozen_string_literal: true

require_relative '../test_helper'

# Pure-Ruby surface of Wurk::Swarm — initialization, validation, and the
# parts that DON'T fork. The fork-real integration sits in
# test/integration/swarm_boot_test.rb.
class SwarmTest < Wurk::Test::UnitCase
  parallelize_me!

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

  # --- boot validation --------------------------------------------------

  def test_boot_raises_on_empty_topology
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.new, config: @config)

    assert_raises(ArgumentError) { swarm.boot(install_signals: false) }
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
end
