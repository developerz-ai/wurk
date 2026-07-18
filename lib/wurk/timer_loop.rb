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

    def wait
      @mutex.synchronize do
        @sleeper.wait(@mutex, @interval) unless @done
      end
    end
  end
end
