# frozen_string_literal: true

require_relative '../heartbeat'

module Wurk
  class Swarm
    # Parent-side child liveness. A child can stay alive as a pid while doing
    # nothing — a deadlocked VM, a C extension holding the GVL, a heartbeat
    # thread that died — and the supervisor only ever reaped exits, so such a
    # child held its slot (and its private-list jobs) until someone noticed.
    #
    # Every `check_interval` the swarm hands over its live pids; one pipelined
    # HGET of each child's `beat` field answers whether that child's heartbeat
    # has MOVED since the last look. A child whose beat has not moved for
    # `timeout` seconds gets TERM (an ordinary drain), and SIGKILL `kill_after`
    # seconds later if it is still there. Its exit then takes the swarm's normal
    # crash-respawn path. Each step is logged.
    #
    # Progress is tracked on the parent's monotonic clock — "the beat value
    # changed" — never by comparing the child's wall-clock `beat` to ours, so
    # an NTP step cannot kill (or spare) a whole fleet.
    #
    # Not judged:
    #   * a child that has never beaten gets `boot_grace` on top of `timeout`
    #     from the first look (fork → `:startup` hooks → first beat);
    #   * anything while `paused:` (quiet, rolling restart / recycle in
    #     flight) — the swarm is deliberately churning, and progress is
    #     forgotten so every child gets a fresh window afterwards;
    #   * anything after a probe failed — children cannot beat into a Redis the
    #     parent cannot read either, so the next successful probe starts every
    #     child over instead of killing the fleet the moment Redis comes back.
    #
    # Collaborators are injected (Config) so this is unit-testable with fakes,
    # like Swarm::Restart.
    class Liveness
      DEFAULT_TIMEOUT = 60
      CHECK_INTERVAL = 5
      # Below two beat intervals a single delayed beat would read as death.
      MIN_TIMEOUT = 2 * Heartbeat::BEAT_PAUSE

      Config = Struct.new(:beats, :kill, :now, :logger, :timeout, :kill_after, :boot_grace, :check_interval,
                          keyword_init: true)

      # nil/false/0 disables supervision; anything else must clear MIN_TIMEOUT.
      def self.timeout_from(value)
        return DEFAULT_TIMEOUT if value.nil?
        return nil if value == false || value.to_s == '0'

        seconds = Float(value)
        if seconds < MIN_TIMEOUT
          raise ArgumentError, "swarm_heartbeat_timeout must be >= #{MIN_TIMEOUT}s (got #{value})"
        end

        seconds
      end

      def initialize(config)
        @beats = config.beats            # ->(pids) => { pid => beat String | nil }; raises if Redis is unreadable
        @kill = config.kill              # ->(pid, sig)
        @now = config.now                # -> monotonic seconds
        @logger = config.logger
        @timeout = config.timeout
        @kill_after = config.kill_after
        @boot_grace = config.boot_grace
        @check_interval = config.check_interval || CHECK_INTERVAL
        @progress = {}                   # pid => [last beat value, monotonic time it was last seen moving]
        @terminating = {}                # pid => { kill_at:, killed: }
        @next_check = 0
        @blind = false
      end

      def tick(pids, paused:)
        now = @now.call
        escalate(now)
        if paused
          @progress.clear
          return
        end
        return if now < @next_check

        @next_check = now + @check_interval
        check(pids - @terminating.keys, now)
      end

      # Reaper hook: the child is gone, whatever killed it.
      def forget(pid)
        @progress.delete(pid)
        return unless @terminating.delete(pid)

        @logger.warn { "swarm: unresponsive child #{pid} exited; slot goes through normal respawn" }
      end

      def terminating?(pid)
        @terminating.key?(pid)
      end

      private

      def check(pids, now)
        beats = probe(pids)
        return unless beats

        pids.each { |pid| observe(pid, beats[pid], now) }
        @progress.select! { |pid, _| pids.include?(pid) }
      end

      def probe(pids)
        return {} if pids.empty?

        beats = @beats.call(pids)
        if @blind
          @blind = false
          @progress.clear
        end
        beats
      rescue StandardError => e
        @blind = true
        @logger.warn { "swarm: liveness probe failed (#{e.class}: #{e.message}); not judging children" }
        nil
      end

      def observe(pid, beat, now)
        last = @progress[pid]
        if last.nil?
          @progress[pid] = [beat, beat ? now : now + @boot_grace]
        elsif beat && beat != last[0]
          @progress[pid] = [beat, now]
        elsif now - last[1] > @timeout
          terminate(pid, now - last[1], now)
        end
      end

      def terminate(pid, idle, now)
        @logger.warn do
          "swarm: child #{pid} heartbeat stale for #{idle.round}s (limit #{@timeout.round}s); sending TERM"
        end
        @progress.delete(pid)
        @terminating[pid] = { kill_at: now + @kill_after, killed: false }
        @kill.call(pid, 'TERM')
      end

      def escalate(now)
        @terminating.each do |pid, state|
          next if state[:killed] || now < state[:kill_at]

          @logger.error { "swarm: child #{pid} still running #{@kill_after.round}s after TERM; sending KILL" }
          state[:killed] = true
          @kill.call(pid, 'KILL')
        end
      end
    end
  end
end
