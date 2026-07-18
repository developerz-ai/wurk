# frozen_string_literal: true

module Wurk
  class Swarm
    # Non-blocking rolling-restart / recycle state machine. One slot is in
    # flight at a time; `advance` moves it a single phase per supervise tick so
    # the supervisor never blocks on a restart and keeps honoring TERM:
    #
    #   spawn_replacement → await_heartbeat(heartbeat_wait) → term_old
    #     → await_exit(drain_timeout) → done
    #
    # The reaper reports child exits via `claim_exit`, so a replacement that
    # dies before it heartbeats is seen as dead (not "slow"): the old child is
    # kept, a per-slot backoff applied, and the slot retried. `abort` drops
    # everything — the swarm's TERM handler then drains the in-flight
    # replacement + old as ordinary children.
    #
    # Collaborators are injected (Config) so the machine is decoupled from the
    # swarm's fork/kill/Redis internals and unit-testable against fakes.
    class Restart
      Config = Struct.new(:spawn, :kill, :heartbeat, :describe, :now, :logger,
                          :heartbeat_wait, :drain_timeout, :backoff, keyword_init: true)

      def initialize(config)
        @spawn = config.spawn            # ->(slot, idx) => replacement pid (registered by the swarm)
        @kill = config.kill              # ->(pid, sig)
        @heartbeat = config.heartbeat    # ->(pid) => truthy once the child has beaten
        @describe = config.describe      # ->(pid) => { slot:, index: } | nil
        @now = config.now                # -> monotonic seconds
        @logger = config.logger
        @heartbeat_wait = config.heartbeat_wait
        @drain_timeout = config.drain_timeout
        @backoff = config.backoff
        @queue = []
        @current = nil
      end

      def idle?
        @current.nil? && @queue.empty?
      end

      # Queue live child PIDs for restart, skipping any already queued or in
      # flight so recycle + rolling restart can't double up on one slot.
      def enqueue(pids)
        pids.each do |pid|
          next if in_flight?(pid) || @queue.include?(pid)

          @queue << pid
        end
      end

      # Reaper hook. Returns true when `pid` belonged to the in-flight restart
      # so the swarm skips crash-respawn for it. A replacement is only claimed
      # while awaiting its heartbeat — once it takes over the slot (await_exit),
      # its death is an ordinary crash the swarm respawns.
      def claim_exit(pid) # rubocop:disable Naming/PredicateMethod
        return false unless @current

        if pid == @current[:old_pid]
          @current[:old_exited] = true
          true
        elsif pid == @current[:replacement] && @current[:phase] == :await_heartbeat
          @current[:replacement_dead] = true
          true
        else
          false
        end
      end

      def advance
        start_next if @current.nil?
        return if @current.nil?

        case @current[:phase]
        when :await_heartbeat then advance_await_heartbeat
        when :await_exit then advance_await_exit
        end
      end

      # TERM/INT: forget queued + in-flight work. The replacement and old child
      # are ordinary children the swarm's shutdown TERMs and drains.
      def abort
        @queue.clear
        @current = nil
      end

      private

      def in_flight?(pid)
        return false unless @current

        pid == @current[:old_pid] || pid == @current[:replacement]
      end

      def start_next
        pid = next_ready_pid
        return unless pid

        meta = @describe.call(pid)
        replacement = spawn_replacement(pid, meta)
        return unless replacement

        @current = { old_pid: pid, index: meta[:index], replacement: replacement,
                     phase: :await_heartbeat, deadline: now + @heartbeat_wait }
        @logger.info { "swarm: restarting slot #{meta[:index]} (old #{pid} -> new #{replacement})" }
      end

      # Spawn the replacement, requeuing the slot on a fork/resource failure so
      # the restart work item isn't lost (and the error can't escape the
      # supervise loop). A per-slot backoff paces the retry — next_ready_pid
      # leaves the head queued until it elapses.
      def spawn_replacement(pid, meta)
        @spawn.call(meta[:slot], meta[:index])
      rescue StandardError => e
        delay = @backoff.fail(meta[:index], lifetime: 0.0)
        @queue.unshift(pid)
        @logger.warn do
          "swarm: replacement spawn for slot #{meta[:index]} failed (#{e.class}: #{e.message}); retry in #{delay}s"
        end
        nil
      end

      # Head of the queue if its old child still exists and its retry backoff
      # has elapsed. Drops a stale head whose old child already vanished; leaves
      # the head queued (returns nil) while a retry backoff is pending, so a
      # slot whose replacement won't boot doesn't cascade into the next slot.
      def next_ready_pid
        pid = @queue.first
        return nil unless pid

        meta = @describe.call(pid)
        if meta.nil?
          @queue.shift
          return nil
        end
        return nil unless @backoff.ready?(meta[:index])

        @queue.shift
      end

      def advance_await_heartbeat
        cur = @current
        return retry_slot if cur[:replacement_dead]

        seen = @heartbeat.call(cur[:replacement])
        timed_out = now >= cur[:deadline]
        return unless seen || timed_out

        warn_heartbeat_timeout(cur) if timed_out && !seen
        @kill.call(cur[:old_pid], 'TERM')
        cur[:phase] = :await_exit
        cur[:deadline] = now + @drain_timeout
      end

      def advance_await_exit
        cur = @current
        return finish(cur) if cur[:old_exited]
        return if now < cur[:deadline]

        # SIGKILL an overrunning old child once, then wait for the reaper to
        # confirm the exit before finishing — finishing early would let the
        # later reap look like a fresh crash and spawn a surplus child.
        return if cur[:killed]

        @kill.call(cur[:old_pid], 'KILL')
        cur[:killed] = true
      end

      def finish(cur)
        @backoff.clear(cur[:index])
        @current = nil
      end

      def retry_slot
        cur = @current
        delay = @backoff.fail(cur[:index], lifetime: 0.0)
        @queue.unshift(cur[:old_pid])
        @logger.warn do
          "swarm: replacement #{cur[:replacement]} for slot #{cur[:index]} died; " \
            "keeping #{cur[:old_pid]}, retry in #{delay}s"
        end
        @current = nil
      end

      def warn_heartbeat_timeout(cur)
        @logger.warn do
          "swarm: replacement #{cur[:replacement]} heartbeat not seen in #{@heartbeat_wait}s; proceeding to TERM old"
        end
      end

      def now
        @now.call
      end
    end
  end
end
