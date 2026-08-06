# frozen_string_literal: true

require_relative '../component'
require_relative '../timer_loop'
require_relative 'history'

module Wurk
  module Metrics
    # Drains Wurk::Metrics::History's in-process accumulator into Redis every
    # `History::FLUSH_INTERVAL` seconds.
    #
    # Deliberately NOT leader-gated, unlike every other periodic component here
    # (Metrics::Rollup, Metrics::QueueRollup, Wurk::History). Those publish
    # *cluster* state that one process should own; this publishes counters that
    # only exist inside this process's memory and that no other process can
    # write. A leader gate would strand every follower's metrics until it died.
    #
    # One tick per process, not per capsule: the accumulator is process-wide and
    # already keyed by the pool each capsule's jobs recorded through.
    class Flusher
      include Component

      # `accumulator` is a collaborator, not an option: every real boot flushes
      # the process-wide one. Tests inject their own so a broken pool stays
      # inside the test that built it.
      def initialize(config, accumulator: History::ACCUMULATOR)
        @config = config
        @accumulator = accumulator
        @timer = TimerLoop.new(History::FLUSH_INTERVAL)
        @thread = nil
      end

      def start
        return @thread if @thread

        @timer.reset
        @thread = safe_thread('metrics-flush') { @timer.run { tick } }
      end

      # Flushes once more in an `ensure`: this stops the only thread that would
      # have written the window accumulated since the last tick, so without it a
      # graceful shutdown would drop up to FLUSH_INTERVAL of counters — the cost
      # the sign-off accepts for a *hard* kill only.
      #
      # Launcher#stop joins the manager drains before the teardown tail reaches
      # us, so by the time this runs no job is still recording.
      #
      # Cleared only on a confirmed join (Thread#join returns nil on timeout): a
      # wedged thread must stay tracked so #start's guard returns it instead of
      # calling @timer.reset, which would un-terminate the loop it is still
      # inside and leave two threads draining the same accumulator.
      def terminate
        @timer.terminate
        @thread = nil if @thread&.join(TimerLoop::JOIN_TIMEOUT)
      ensure
        tick
      end

      # Never raises: this runs on a `safe_thread`, whose watchdog re-raises
      # after reporting, and a reported-then-dead flusher would silently stop
      # every counter in the process for a blip Redis recovers from. The
      # accumulator has already merged the failed window back for the next tick.
      def tick
        History.flush(@accumulator)
      rescue StandardError => e
        handle_exception(e, { context: 'metrics-flush' })
      end
    end
  end
end
