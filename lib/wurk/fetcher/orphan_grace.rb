# frozen_string_literal: true

module Wurk
  class Fetcher
    # The Reaper's wait between judging a list orphaned by its heartbeat and
    # draining it.
    #
    # A live owner can read as having no heartbeat hash: its first beat failed on
    # a Redis blip, CPU-bound jobs held the beat back, or Redis restarted from an
    # older snapshot. Its next beat lands within the wait, and that spares it.
    #
    # The clock is this process's own and it is shared by nothing else, so it
    # costs the same on every server and at every fleet size. That is the
    # difference from what it replaces, OBJECT IDLETIME: any read of the list
    # (a monitor's LLEN) reset that clock, some servers do not have the command,
    # and a clock kept per sweep only advanced in a process that won the sweep
    # lock twice. The loop thread therefore finishes what any sweep here started,
    # with or without the lock (Reaper#drain_settled).
    class OrphanGrace
      # Lists remembered at once. Past it the memory restarts, and every clock
      # restarting is the conservative direction: the next sweep judges them anew.
      MEMORY = 10_000

      Entry = Struct.new(:since, :owner)

      def initialize(grace)
        @grace = grace
        @lock = ::Mutex.new
        @entries = {}
      end

      # true while the list must be left alone. `owner` is what #take_settled
      # hands back when the wait is over.
      def recent?(key, owner)
        return false unless @grace.positive?

        now = monotonic
        @lock.synchronize do
          @entries.clear if @entries.size >= MEMORY && !@entries.key?(key)
          entry = (@entries[key] ||= Entry.new(now, owner))
          next true if now - entry.since < @grace

          @entries.delete(key)
          false
        end
      end

      # The owner came back: its next judgement starts a new wait.
      def forget(key)
        @lock.synchronize { @entries.delete(key) }
      end

      # [[key, owner], ...] whose wait is over, removed from memory.
      def take_settled
        now = monotonic
        @lock.synchronize do
          settled = @entries.select { |_, entry| now - entry.since >= @grace }
          settled.each_key { |key| @entries.delete(key) }
          settled.map { |key, entry| [key, entry.owner] }
        end
      end

      # Seconds until the next wait ends, nil with nothing waiting.
      def next_due_in
        now = monotonic
        @lock.synchronize do
          oldest = @entries.each_value.map(&:since).min
          oldest && [(oldest + @grace) - now, 0].max
        end
      end

      def size
        @lock.synchronize { @entries.size }
      end

      private

      def monotonic
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
