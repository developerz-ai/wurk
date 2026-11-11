# frozen_string_literal: true

require_relative '../test_helper'

# A swarm that owns its signals titles its process after the binary that started
# it; one co-hosted in a web server (install_signals: false) leaves the host's.
class SwarmProctitleTest < Wurk::Test::UnitCase
  def setup
    super
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:tag] = 'myapp'
    @swarm = Wurk::Swarm.new(topology: Wurk::Topology.flat(count: 2, queues: ['default'], concurrency: 1),
                             config: @config)
    @swarm.instance_variable_set(:@assignments, @swarm.topology.assignments)
    @swarm.instance_variable_get(:@children)[4242] = { index: 0 }
    @saved_title = $PROGRAM_NAME
    $PROGRAM_NAME = 'host'
  end

  def teardown
    $PROGRAM_NAME = @saved_title
  ensure
    super
  end

  def test_a_signal_owning_swarm_titles_its_process
    @swarm.instance_variable_set(:@title_program, 'sidekiqswarm')
    @swarm.send(:update_proctitle)

    assert_equal 'sidekiqswarm myapp [1 of 2 processes]', $PROGRAM_NAME
  end

  def test_a_co_hosted_swarm_leaves_the_hosts_title
    @swarm.send(:update_proctitle)

    assert_equal 'host', $PROGRAM_NAME
  end
end
