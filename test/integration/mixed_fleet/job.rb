# frozen_string_literal: true

# The job both fleets in mixed_fleet_test.rb run. Passed to `sidekiq` and to
# `wurkswarm` as `-r`, so it loads after either engine and `Sidekiq::Job` is the
# real gem's on one side and Wurk's alias on the other: the job code is the same
# bytes, only the engine differs (as in bench/vs_sidekiq/job.rb).
#
# Every attempt and completion lands in the jid ledger (bench/soak/ledger.rb)
# with the engine that ran it, so the test can tell who ran what.

require_relative '../../../bench/soak/ledger'

MIXED_FLEET_ENGINE = defined?(Wurk) ? 'wurk' : 'sidekiq'
# A `hold` job parks until this key exists, so the test can stop or kill a
# worker while it is provably in flight.
MIXED_FLEET_RELEASE_KEY = 'mixed-fleet:release'
MIXED_FLEET_HOLD_LIMIT = 120

Sidekiq.configure_server do |config|
  # Both pollers otherwise wait 5-15s before their first pass and then poll
  # every few seconds per process; the test waits on promotion, not on timers.
  config[:poll_interval_average] = 1
  config[:scheduler_initial_wait] = 0
end

class MixedFleetJob
  include Sidekiq::Job

  sidekiq_options retry: false

  def perform(kind)
    WurkSoak::Ledger.record('run', jid, kind, MIXED_FLEET_ENGINE)
    kind == 'hold' ? hold : sleep(0.005)
    WurkSoak::Ledger.record('done', jid, kind, MIXED_FLEET_ENGINE)
  end

  private

  def hold
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + MIXED_FLEET_HOLD_LIMIT
    until Sidekiq.redis { |conn| conn.call('EXISTS', MIXED_FLEET_RELEASE_KEY) } == 1
      raise "hold job #{jid} never released" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end
end
