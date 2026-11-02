# frozen_string_literal: true

module Wurk
  # Lets the first report of a key through, then one per window, and says how
  # many it swallowed in between. Per process: every forked child speaks for
  # itself, so a fleet still reports at worst children x keys per window.
  class ErrorCoalescer
    DEFAULT_WINDOW = 60

    def initialize(window: DEFAULT_WINDOW, clock: -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) })
      @window = window
      @clock = clock
      @lock = ::Mutex.new
      @entries = {}
    end

    # The number of reports suppressed since the last one when this one should
    # go out (0 for a first report); nil when this one should be swallowed.
    def admit(key)
      @lock.synchronize do
        now = @clock.call
        entry = (@entries[key] ||= [nil, 0])
        if entry[0] && now - entry[0] < @window
          entry[1] += 1
          next nil
        end

        suppressed = entry[1]
        entry[0] = now
        entry[1] = 0
        suppressed
      end
    end
  end
end
