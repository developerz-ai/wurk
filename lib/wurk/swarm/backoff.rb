# frozen_string_literal: true

module Wurk
  class Swarm
    # Per-key exponential backoff timer with survival-based reset. Pure
    # bookkeeping — no sleeping, no I/O — so the supervise thread never blocks
    # on it: it records a failure, then asks `ready?` each tick and acts only
    # once the delay has elapsed.
    #
    # Delay grows base → 2·base → 4·base … capped at `cap`. A key whose child
    # survived at least `reset_after` seconds counts as a fresh first failure,
    # so a slot that ran healthily for a while doesn't inherit an old crash
    # streak. Keyed by slot index for crash-respawn and (in Swarm::Restart) for
    # replacement-retry delays.
    class Backoff
      BASE = 1.0
      CAP = 30.0
      RESET_AFTER = 60.0

      def initialize(base: BASE, cap: CAP, reset_after: RESET_AFTER, clock: nil)
        @base = base
        @cap = cap
        @reset_after = reset_after
        @clock = clock || -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) }
        @streak = Hash.new(0)
        @due_at = {}
      end

      # Record a failure and schedule the next attempt. `lifetime` is how long
      # the failed child lived; >= reset_after resets the streak. Returns the
      # delay applied.
      def fail(key, lifetime: 0.0)
        @streak[key] = 0 if lifetime >= @reset_after
        @streak[key] += 1
        delay = [@base * (2**(@streak[key] - 1)), @cap].min
        @due_at[key] = now + delay
        delay
      end

      # A retry is scheduled and not yet issued.
      def pending?(key)
        @due_at.key?(key)
      end

      # The scheduled delay has elapsed (or nothing is scheduled).
      def ready?(key)
        at = @due_at[key]
        at.nil? || now >= at
      end

      # Mark the scheduled retry as issued without resetting the streak, so a
      # child that crashes straight back escalates toward the cap.
      def consume(key)
        @due_at.delete(key)
      end

      # Forget the key entirely (slot retired or restart succeeded).
      def clear(key)
        @streak.delete(key)
        @due_at.delete(key)
      end

      private

      def now
        @clock.call
      end
    end
  end
end
