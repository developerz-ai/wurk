# frozen_string_literal: true

# Spawned by test/integration/swarm_child_features_test.rb in a fresh Ruby, so
# the parent's $LOADED_FEATURES are what `require "wurk"` plus Swarm#boot load,
# not the whole suite's. Boots a one-child swarm, has the child run a job that
# reports every feature it loaded after the fork, and prints that list as JSON.
#
#   ruby -Ilib test/fixtures/swarm_child_features_probe.rb <queue> <result key>

require 'json'
require 'logger'
require 'wurk'

queue = ARGV.fetch(0)
key = ARGV.fetch(1)
Wurk.configuration.logger = Logger.new(IO::NULL)

class FeatureProbeJob
  include Wurk::Job

  def perform(key)
    loaded_after_fork = $LOADED_FEATURES - $wurk_parent_features # rubocop:disable Style/GlobalVars
    Wurk.redis { |c| c.call('SET', key, JSON.dump(loaded_after_fork), 'EX', 60) }
  end
end

# The features the child inherits are the parent's at its first fork.
class FeatureProbeSwarm < Wurk::Swarm
  private

  def fork_child(*)
    $wurk_parent_features ||= $LOADED_FEATURES.dup # rubocop:disable Style/GlobalVars
    super
  end
end

swarm = FeatureProbeSwarm.new(topology: Wurk::Topology.flat(count: 1, queues: [queue], concurrency: 1),
                              config: Wurk.configuration, shutdown_timeout: 5)
swarm.boot(install_signals: false)
FeatureProbeJob.set(queue: queue).perform_async(key)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
result = nil
until result || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  result = Wurk.redis { |c| c.call('GET', key) }
  sleep 0.05
end
swarm.shutdown(timeout: 5)
abort 'the probe job never ran' unless result
puts result
