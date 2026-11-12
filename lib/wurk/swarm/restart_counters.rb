# frozen_string_literal: true

require 'tmpdir'
require 'securerandom'

module Wurk
  class Swarm
    # The supervisor's child-restart counts and current crash streak, for the
    # `/metrics` of whichever child owns the health port. The parent runs no
    # listener and has no Redis key of its own, so it writes them into an
    # unlinked file it opened before the first fork: every child, respawns
    # included, inherits the descriptor and reads the parent's latest write
    # with one pread. No Redis key, no socket.
    #
    # One writer (the supervise thread) and a fixed 40-byte record at offset 0.
    # A pread racing the pwrite can mix fields from the two records; each field
    # is still a value it held (counters only grow), so a scrape never exports
    # one that never existed, and the next scrape reads the settled record.
    class RestartCounters
      REASONS = %i[crash recycle liveness rolling].freeze
      FORMAT = 'Q<5'
      SIZE = 8 * (REASONS.size + 1)

      Snapshot = Struct.new(:restarts, :crash_streak)

      # nil when no temp file can be opened; the swarm runs without the metric.
      def self.open(dir = ::Dir.tmpdir, logger: nil)
        path = ::File.join(dir, "wurk-swarm-#{::Process.pid}-#{::SecureRandom.hex(6)}")
        file = ::File.new(path, ::File::RDWR | ::File::CREAT | ::File::EXCL, 0o600)
        ::File.unlink(path)
        new(file)
      rescue ::SystemCallError => e
        logger&.warn { "swarm: restart counters unavailable (#{e.class}: #{e.message}); not exported" }
        nil
      end

      def initialize(file)
        @io = file
        @restarts = REASONS.to_h { |reason| [reason, 0] }
        @crash_streak = 0
        write
      end

      def record_restart(reason)
        @restarts[REASONS.include?(reason) ? reason : :crash] += 1
        write
      end

      def crash_streak=(streak)
        return if streak == @crash_streak

        @crash_streak = streak
        write
      end

      # The parent's latest record; nil when it cannot be read.
      def read
        values = @io.pread(SIZE, 0)&.unpack(FORMAT)
        return nil unless values && values.size == SIZE / 8

        Snapshot.new(REASONS.zip(values).to_h, values.last)
      rescue ::IOError, ::SystemCallError
        nil
      end

      def close
        @io.close unless @io.closed?
      end

      private

      def write
        @io.pwrite([*@restarts.values, @crash_streak].pack(FORMAT), 0)
      rescue ::IOError, ::SystemCallError
        nil
      end
    end
  end
end
