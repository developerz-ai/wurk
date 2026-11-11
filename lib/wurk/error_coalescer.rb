# frozen_string_literal: true

module Wurk
  # Lets the first report of a key through, then one per window, and says how
  # many it swallowed in between. Per process: every forked child speaks for
  # itself, so a fleet still reports at worst children x keys per window.
  #
  # Keys can come from data (an error message's first word), so at most
  # MAX_KEYS are remembered: a new key first evicts the keys whose window has
  # passed with nothing swallowed, then, if still full, the oldest. An evicted
  # key's next report goes straight out.
  class ErrorCoalescer
    DEFAULT_WINDOW = 60
    MAX_KEYS = 1024

    def initialize(window: DEFAULT_WINDOW, max_keys: MAX_KEYS,
                   clock: -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) })
      @window = window
      @max_keys = max_keys
      @clock = clock
      @lock = ::Mutex.new
      @entries = {}
    end

    # The number of reports suppressed since the last one when this one should
    # go out (0 for a first report); nil when this one should be swallowed.
    def admit(key)
      @lock.synchronize do
        now = @clock.call
        make_room(now) unless @entries.key?(key)
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

    def size = @lock.synchronize { @entries.size }

    private

    def make_room(now)
      return if @entries.size < @max_keys

      @entries.delete_if { |_, (at, swallowed)| swallowed.zero? && now - at >= @window }
      @entries.shift while @entries.size >= @max_keys
    end
  end
end
