# frozen_string_literal: true

require_relative '../keys'

module Wurk
  module Status
    # The in-job progress handle: `status.at(row, total, 'importing')`.
    #
    # Writes are coalesced. A job looping over 100k rows and reporting each one
    # must not become 100k Redis round trips, so at most one write lands per
    # {INTERVAL}; the newest unwritten values are buffered and `#flush` (called
    # by the server middleware on the way out) always persists the last thing
    # the job said. The first report is never delayed — a job that calls `at`
    # once, early, is visible immediately.
    #
    # Not thread-safe: one handle belongs to one job execution on one thread,
    # the same contract IterableJob's cursor state has.
    class Progress
      # Coalescing window, seconds. Mirrors IterableJob::STATE_FLUSH_INTERVAL —
      # a job checkpointing its own state and a job reporting progress are the
      # same traffic problem, and two different answers to it would just be
      # two numbers to tune.
      INTERVAL = 5

      attr_reader :jid

      def initialize(jid, ttl: Keys::STATUS_TTL, interval: INTERVAL, pool: nil)
        @jid      = jid.to_s
        @ttl      = ttl
        @interval = interval
        @pool     = pool
        @pending  = {}
        @wrote_at = nil
      end

      # Report position. `total` and `message` are optional and sticky: pass
      # them once and later bare `at(n)` calls keep them.
      #
      # @return [Integer] num, so `at` can wrap an existing counter expression
      def at(num, total = nil, message = nil)
        @pending[:progress] = num.to_i
        @pending[:total]    = total.to_i unless total.nil?
        @pending[:message]  = message.to_s unless message.nil?
        maybe_write
        num
      end

      # Report a human-readable step without moving the counter.
      def message(text)
        @pending[:message] = text.to_s
        maybe_write
        text
      end

      # Force out whatever `at`/`message` buffered since the last write.
      #
      # @return [Boolean] true when something was written
      def flush
        return false if @pending.empty?

        write
      end

      private

      def maybe_write
        return false if @wrote_at && monotonic - @wrote_at < @interval

        write
      end

      # `create: false`: progress never resurrects a row whose job already
      # finished, or whose TTL lapsed while a long job ran. The buffer is
      # cleared either way — a dropped write means the row is gone, and
      # re-sending the same stale values later would not bring it back.
      def write
        wrote = Status.write(@jid, ttl: @ttl, create: false, pool: @pool, **@pending)
        @pending = {}
        @wrote_at = monotonic
        wrote
      end

      # Monotonic, not wall clock: the window is a duration, and a job holding
      # this handle for hours must not skip or storm writes because ntp stepped
      # the clock.
      def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
