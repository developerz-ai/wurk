# frozen_string_literal: true

require_relative 'component'
require_relative 'launcher'
require_relative 'fetcher/reliable'
require_relative 'keys'
require_relative 'swarm/child_boot'
require_relative 'swarm/backoff'
require_relative 'swarm/restart'

module Wurk
  # Parent supervisor. Forks N children per the worker topology, monitors
  # PIDs, relays signals, respawns crashed children with per-slot exponential
  # backoff, handles rolling restart on SIGUSR1, recycles RSS-bloated children.
  #
  # The supervise loop never sleeps on behalf of a respawn or a restart: crash
  # backoff is tracked as per-slot due-times (Swarm::Backoff) and rolling
  # restart / recycle run as a non-blocking state machine (Swarm::Restart)
  # advanced one phase per tick. TERM/INT is therefore honored within a tick
  # regardless of restart or backoff state.
  #
  # Boot ordering (must be exact — see docs/idea/03-process-model.md):
  #   1. Host app boots fully; eager loads done.
  #   2. Railtie `after_initialize` fires.
  #   3. `boot` closes parent-side connections (Redis, ActiveRecord).
  #   4. `boot` forks N children.
  #   5. Each child reconnects DB + opens a fresh Redis pool, then
  #      installs its own signal handlers and starts the Launcher.
  #   6. Parent calls `supervise` to enter the wait/relay loop.
  #
  # Signals (see docs/idea/04-signals.md):
  #   TERM/INT  → `shutdown`           (graceful drain; aborts any restart)
  #   TSTP      → relay TSTP           (quiet — stop fetching; one-way, no resume)
  #   USR1      → `rolling_restart`    (zero-downtime cycle)
  class Swarm
    include Component

    SUPERVISE_TICK = 0.2
    RESPAWN_BACKOFF = 1.0
    HEARTBEAT_WAIT = 30
    MEMORY_CHECK_INTERVAL = 10
    DEFAULT_SHUTDOWN_TIMEOUT = 25

    attr_reader :topology, :children

    def initialize(topology:, config: Wurk.configuration, memory_limit: config.memory_limit_kb,
                   shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT)
      @topology = topology
      @config = config
      @memory_limit = memory_limit
      @shutdown_timeout = shutdown_timeout
      @children = {}
      @assignments = []
      @stopping = false
      @last_memory_check = 0
      @signal_queue = ::Thread::Queue.new
      @respawn_backoff = Backoff.new(base: RESPAWN_BACKOFF)
      @restart = build_restart
    end

    # `install_signals:` is false in tests so the integration suite can
    # drive `shutdown` / `rolling_restart` directly without poisoning the
    # test process's signal handlers.
    def boot(install_signals: true)
      raise 'Wurk::Swarm already booted' unless @assignments.empty?
      raise ArgumentError, 'Topology has no slots' if @topology.empty?

      @assignments = @topology.assignments.freeze
      close_parent_sockets
      fork_children
      install_signal_handlers if install_signals
      @children.keys
    end

    def supervise
      until done?
        drain_signals
        reap_children
        spawn_due_respawns
        @restart.advance unless @stopping
        check_memory_pressure
        sleep SUPERVISE_TICK
      end
    end

    def shutdown(timeout: @shutdown_timeout)
      @stopping = true
      @restart.abort
      relay_signal('TERM')
      wait_for_children(timeout)
      hard_kill_stragglers
    end

    # SIGUSR1: queue every live child for the rolling-restart state machine,
    # which replaces one slot at a time (spawn replacement → await its
    # heartbeat → TERM the old child → await its drain) without blocking the
    # supervise thread, so TERM stays responsive throughout the cycle.
    def rolling_restart
      @restart.enqueue(@children.keys)
    end

    private

    def build_restart
      Restart.new(Restart::Config.new(
                    spawn: method(:spawn_child),
                    kill: method(:safe_kill),
                    heartbeat: method(:heartbeat_seen?),
                    describe: ->(pid) { @children[pid] },
                    now: method(:monotonic),
                    logger: logger,
                    heartbeat_wait: HEARTBEAT_WAIT,
                    drain_timeout: @shutdown_timeout,
                    backoff: Backoff.new(base: RESPAWN_BACKOFF)
                  ))
    end

    # Step 3.
    def close_parent_sockets
      @config.reset_redis_pools!
      close_active_record_pool
    end

    def close_active_record_pool
      return unless defined?(::ActiveRecord::Base)

      ::ActiveRecord::Base.connection_handler.clear_active_connections!
      ::ActiveRecord::Base.connection_handler.flush_idle_connections!
    rescue StandardError => e
      logger.warn { "swarm: ActiveRecord close failed: #{e.class}: #{e.message}" }
    end

    # Step 4.
    def fork_children
      @assignments.each_index { |idx| spawn_child(@assignments[idx], idx) }
    end

    # Fork one child for the slot and record its spawn time so crash backoff can
    # tell a crash-loop (short-lived) from a healthy child that finally died.
    # Returns the child PID; never returns in the child (ChildBoot exits).
    def spawn_child(slot, idx)
      pid = fork_child(slot, idx)
      @children[pid] = { slot: slot, index: idx, spawned_at: monotonic }
      pid
    end

    def fork_child(slot, idx)
      pid = ::Process.fork
      return pid if pid

      ChildBoot.new(@config, slot, idx).run
      exit 0 # unreachable; ChildBoot exits explicitly
    end

    def install_signal_handlers
      { 'TERM' => :term, 'INT' => :term, 'TSTP' => :tstp,
        'USR1' => :usr1 }.each do |sig, sym|
        ::Signal.trap(sig) { @signal_queue << sym }
      end
    end

    def drain_signals
      until @signal_queue.empty?
        sym = next_signal_symbol
        next if sym.nil?

        case sym
        when :term then shutdown
        when :tstp then relay_signal('TSTP')
        when :usr1 then rolling_restart
        end
      end
    end

    def next_signal_symbol
      @signal_queue.pop(true)
    rescue ThreadError
      nil
    end

    # Reap every exited child this tick (not one), so a fleet-wide death
    # recovers in parallel rather than one child per SUPERVISE_TICK. ECHILD
    # (momentarily no children — all crashed and awaiting backoff) is not a stop
    # condition: the swarm only stops on an explicit TERM/INT.
    def reap_children
      loop do
        pid, status = ::Process.wait2(-1, ::Process::WNOHANG)
        break unless pid

        on_child_exit(pid, status)
      end
    rescue Errno::ECHILD
      nil
    end

    def on_child_exit(pid, status)
      meta = @children.delete(pid)
      return unless meta
      return if @restart.claim_exit(pid)

      if @stopping
        logger.info { "swarm: child #{pid} exited (status=#{status.exitstatus})" }
      else
        schedule_respawn(pid, status, meta)
      end
    end

    # Arm the slot's backoff instead of sleeping the supervise thread; the next
    # due tick respawns it. A child that lived past the reset window counts as a
    # fresh failure (base delay), so only a genuine crash-loop escalates toward
    # the cap.
    def schedule_respawn(pid, status, meta)
      idx = meta[:index]
      delay = @respawn_backoff.fail(idx, lifetime: monotonic - meta[:spawned_at])
      logger.warn do
        "swarm: child #{pid} died (status=#{status.exitstatus}); respawning slot #{idx} in #{delay}s"
      end
    end

    # Respawn any slot whose backoff window has elapsed. Runs every tick; a
    # no-op until a scheduled respawn comes due.
    def spawn_due_respawns
      return if @stopping

      @assignments.each_index do |idx|
        next unless @respawn_backoff.pending?(idx) && @respawn_backoff.ready?(idx)

        @respawn_backoff.consume(idx)
        spawn_child(@assignments[idx], idx)
      end
    end

    def check_memory_pressure
      return unless @memory_limit

      now = monotonic
      return if now - @last_memory_check < MEMORY_CHECK_INTERVAL

      @last_memory_check = now
      @children.dup.each_key { |pid| recycle_if_bloated(pid) }
    end

    # Route a bloated child through the restart state machine (same path as a
    # rolling restart) so recycle is graceful — a healthy replacement takes over
    # before the old child is TERMed — and can't overlap a restart already in
    # flight on the slot.
    def recycle_if_bloated(pid)
      rss = pid_rss_kb(pid)
      return if rss.nil? || rss < @memory_limit

      logger.warn { "swarm: child #{pid} RSS #{rss}KB >= #{@memory_limit}KB; recycling" }
      @restart.enqueue([pid])
    end

    def pid_rss_kb(pid)
      return nil unless ::File.exist?("/proc/#{pid}/statm")

      ::File.read("/proc/#{pid}/statm").split[1].to_i * 4
    rescue StandardError
      nil
    end

    def relay_signal(sig)
      @children.each_key { |pid| safe_kill(pid, sig) }
    end

    def safe_kill(pid, sig)
      ::Process.kill(sig, pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def wait_for_children(timeout)
      deadline = monotonic + timeout
      while monotonic < deadline && @children.any?
        reap_children
        sleep 0.1
      end
    end

    def hard_kill_stragglers
      @children.each_key { |pid| safe_kill(pid, 'KILL') }
      @children.clear
    end

    # Has the child written its first heartbeat yet? One non-blocking SISMEMBER,
    # polled by the restart state machine each tick. Identity is
    # `<hostname>:<pid>:<nonce>`; PROCESS_NONCE is set when Component loads in
    # the parent and inherited by every fork, so the parent computes a child's
    # identity from its PID alone. A Redis blip returns false (not seen yet) so a
    # transient error can't crash the supervisor — the restart deadline still
    # forces progress.
    def heartbeat_seen?(pid)
      identity = "#{hostname}:#{pid}:#{Component::PROCESS_NONCE}"
      @config.redis { |c| c.call('SISMEMBER', Keys::PROCESSES, identity) } == 1
    rescue StandardError
      false
    end

    def monotonic
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    def done?
      @stopping && @children.empty?
    end
  end
end
