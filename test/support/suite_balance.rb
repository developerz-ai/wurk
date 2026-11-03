# frozen_string_literal: true

module Wurk
  module Test
    # minitest-parallel_fork deals classes round-robin (`j % n == i`) with no work
    # stealing, so a worker that draws the slow classes runs long while the other
    # sits idle. It deals by position, so ordering the list decides the shares: the
    # known-slow classes go to whichever worker has the least so far, the rest are
    # dealt evenly. Measured on one serial run's class times, the longest worker
    # drops from 319s (p50) / 363s (p90) to about 265s at two workers.
    module SuiteBalance
      # Seconds, from a serial run. They only have to rank the slow classes, so they
      # can drift; a class missing here is simply dealt with the rest.
      WEIGHTS = {
        'GlobalConcurrencyTest' => 119, 'SwarmLivenessIntegrationTest' => 34, 'SwarmCliTest' => 33,
        'InterruptHandlerAutoregisterTest' => 31, 'SidekiqRequireShimsTest' => 29, 'DemoSoakTest' => 16,
        'SwarmBootTest' => 15, 'DeployDemoWorkflowTest' => 15, 'GracefulShutdownTest' => 14,
        'TimeoutHangTest' => 11, 'LivenessProbeTest' => 10, 'BatchRetryRoundtripTest' => 9,
        'LauncherTest' => 8, 'PeriodicLeaderTest' => 8, 'RedisOutageRecoveryTest' => 7,
        'RollingRestartTest' => 7, 'TelemetryTest' => 7, 'HealthBriefTest' => 7,
        'SwarmSupervisionTest' => 6, 'FetcherReaperTest' => 5
      }.freeze

      def self.order(suites, workers)
        shares = Array.new(workers) { [] }
        loads = Array.new(workers, 0)
        slow, rest = suites.partition { |suite| WEIGHTS.key?(suite.name) }

        slow.sort_by { |suite| -WEIGHTS.fetch(suite.name) }.each do |suite|
          lightest = loads.index(loads.min)
          shares[lightest] << suite
          loads[lightest] += WEIGHTS.fetch(suite.name)
        end
        rest.each { |suite| shares.min_by(&:size) << suite }

        Array.new(shares.map(&:size).max) { |row| shares.map { |share| share[row] } }.flatten.compact
      end
    end
  end
end
