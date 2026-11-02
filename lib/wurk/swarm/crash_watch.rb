# frozen_string_literal: true

module Wurk
  class Swarm
    # Decides when a fleet has stopped being worth respawning. Pure bookkeeping,
    # clock passed in, like Backoff. Backoff alone retries forever, and a parent
    # that respawns forever stays Running while processing nothing: orchestrators
    # and process-grep probes see a healthy pod.
    #
    # A slot's streak starts at its first young crash and ends when a child
    # outlives `young_within`. The exit is due once EVERY slot has been in an
    # unbroken streak for `exit_after`: one bad slot beside healthy ones is
    # degraded, not dead, and stays the respawn loop's problem.
    #
    # A crash `excused:` by the caller (Redis unreachable) ends the streak too,
    # because the release is not shown to be broken and the swarm's job during
    # an outage is to be there when Redis returns.
    class CrashWatch
      attr_reader :exit_after

      # `exit_after` nil disables the exit; streak counting still feeds the logs.
      def initialize(exit_after:, young_within:)
        @exit_after = exit_after
        @young_within = young_within
        @since = {}
        @streak = Hash.new(0)
      end

      # Returns the slot's streak length after this crash.
      def record(slot, lifetime:, now:, excused: false)
        if excused || lifetime >= @young_within
          clear(slot)
          return excused ? 0 : 1
        end

        @since[slot] ||= now
        @streak[slot] += 1
      end

      def settled(slot, lifetime)
        clear(slot) if lifetime >= @young_within
      end

      def due?(slots, now)
        return false unless @exit_after
        return false if slots.empty?

        slots.all? { |slot| (at = @since[slot]) && now - at >= @exit_after }
      end

      # Restart the clock, so a co-hosted swarm that keeps running reports once
      # per window rather than once per tick.
      def rearm(now)
        @since.transform_values! { now }
      end

      private

      def clear(slot)
        @since.delete(slot)
        @streak.delete(slot)
      end
    end
  end
end
