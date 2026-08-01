# frozen_string_literal: true

module Wurk
  # Mutex/CV "tick every N seconds until told to stop" primitive shared by
  # every leader-gated periodic component (History, Metrics::Rollup,
  # Metrics::QueueRollup). Each of those used to hand-roll the same
  # `@mutex`/`@sleeper`/`@done` dance; this is that dance, extracted once.
  #
  # The host owns thread spawning (it needs its own `safe_thread` from
  # Component for logger/handle_exception context) and the leader-gate check
  # inside its `tick` — TimerLoop only owns the interval wait and the
  # start/terminate signaling around it:
  #
  #   @timer = Wurk::TimerLoop.new(interval)
  #   @thread ||= safe_thread('my-loop') { @timer.run { tick } }
  #   def terminate = @timer.terminate
  class TimerLoop
    # Deadline every periodic component gives its loop thread when stopping.
    # Bounded rather than an open-ended join: a tick blocked on a wedged Redis
    # must not hold the process's whole shutdown open. Also used by
    # Scheduled::Poller, which hand-rolls its wait (the interval is randomized
    # per iteration) but stops on the same terms.
    JOIN_TIMEOUT = 5

    def initialize(interval)
      @interval = interval
      @done = false
      @mutex = ::Mutex.new
      @sleeper = ::ConditionVariable.new
    end

    # Waits one interval, then yields repeatedly (waiting between calls)
    # until #terminate is called. Matches the existing components' "don't
    # tick immediately on boot" behavior.
    def run
      wait
      until @done
        yield
        wait
      end
    end

    def terminate
      @mutex.synchronize do
        @done = true
        @sleeper.signal
      end
    end

    # Clears a previous #terminate. Hosts call this before respawning, so a
    # start-after-stop cycle spawns a thread that ticks instead of one that
    # sees the stale done flag and exits immediately.
    def reset
      @mutex.synchronize { @done = false }
    end

    def wait
      @mutex.synchronize do
        @sleeper.wait(@mutex, @interval) unless @done
      end
    end
  end
end
