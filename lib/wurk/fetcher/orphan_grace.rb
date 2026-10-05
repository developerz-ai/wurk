# frozen_string_literal: true

module Wurk
  class Fetcher
    # The Reaper's boot-grace check: has this heartbeat-judged orphan been
    # left alone for at least `grace` seconds? A booting worker can claim a job
    # a moment before its first heartbeat lands, and draining its list in that
    # window runs the job twice, concurrently.
    #
    # The answer comes from OBJECT IDLETIME, which a live owner resets on every
    # claim and ACK. Some servers refuse it — Redis under an LFU maxmemory
    # policy, Dragonfly with no OBJECT at all — and the grace must not quietly
    # vanish with it. Without IDLETIME the clock is this reaper's own: a list
    # is drained only once it has been judged orphaned for `grace` seconds
    # across sweeps, by which time a booting owner has beaten and the
    # heartbeat re-check spares it. The switch is logged once.
    class OrphanGrace
      NO_IDLETIME_WARNING = 'reaper: OBJECT IDLETIME is unavailable on this Redis (%s); the boot grace ' \
                            'before reclaiming a private list now runs on this process\'s own clock, so an ' \
                            'orphan is drained one sweep later than it would be. Expected under an LFU ' \
                            'maxmemory policy or on servers without OBJECT (e.g. Dragonfly).'

      # Lists remembered for the fallback clock. A list leaves on the pass
      # that clears it; one judged orphaned and then found alive can linger,
      # so the memory is bounded and simply restarts when full — every clock
      # restarting is the conservative direction.
      MEMORY = 10_000

      def initialize(config, grace)
        @config = config
        @grace = grace
        @idletime = true
        @first_seen = {}
      end

      # true while the list must be left alone.
      def recent?(key)
        return false unless @grace.positive?
        return local_recent?(key) unless @idletime

        idle = @config.redis(idempotent: true) { |c| c.call('OBJECT', 'IDLETIME', key) }
        # nil: the list is already gone, nothing to drain.
        idle.nil? || idle < @grace
      rescue RedisClient::CommandError => e
        idletime_unavailable!(e)
        local_recent?(key)
      end

      private

      def local_recent?(key)
        now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        @first_seen.clear if @first_seen.size >= MEMORY && !@first_seen.key?(key)
        seen = (@first_seen[key] ||= now)
        return true if now - seen < @grace

        @first_seen.delete(key)
        false
      end

      def idletime_unavailable!(error)
        @idletime = false
        @config.logger.warn { format(NO_IDLETIME_WARNING, error.message.lines.first&.strip) }
      end
    end
  end
end
