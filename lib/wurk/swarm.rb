# frozen_string_literal: true

require 'monitor'

require_relative 'component'
require_relative 'launcher'
require_relative 'fetcher/reliable'
require_relative 'keys'
require_relative 'swarm/child_boot'
require_relative 'swarm/backoff'
require_relative 'swarm/restart'
require_relative 'swarm/orphan_guard'

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
  class Swarm # rubocop:disable Metrics/ClassLength
    include Component

    SUPERVISE_TICK = 0.2
    RESPAWN_BACKOFF = 1.0
    HEARTBEAT_WAIT = 30
    MEMORY_CHECK_INTERVAL = 10
    DEFAULT_SHUTDOWN_TIMEOUT = 25

    # Children each hard_shutdown after their own drain deadline (bulk_requeue
    # + a 3s ensure window + heartbeat cleanup); the parent must not SIGKILL
    # them mid-tail, so its own wait always extends past theirs by this much.
    SHUTDOWN_GRACE = 5

    # USR2 is relayed (log reopen) — without a trap, a logrotate config that
    # signals the master pid would hit USR2's default disposition and kill the
    # whole swarm.
    SWARM_SIGNALS = { 'TERM' => :term, 'INT' => :term, 'TSTP' => :tstp, 'USR1' => :usr1, 'USR2' => :usr2 }.freeze

    attr_reader :topology

    def initialize(topology:, config: Wurk.configuration, memory_limit: config.memory_limit_kb,
                   shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT)
      @topology = topology
      @config = config
      @memory_limit = memory_limit
      @shutdown_timeout = shutdown_timeout
      # One reentrant lock covers the child table AND the restart machine: they
      # are mutually recursive (Restart#advance calls back into `describe` and
      # `spawn`, which read and write `@children`), so separate locks would be
      # taken in opposite orders — enqueue holds children→restart, advance holds
      # restart→children — and deadlock. Monitor's reentrancy is what lets those
      # callbacks re-enter. Never held across a sleep: `wait_for_children` and
      # the supervise tick sleep outside it.
      @lock = ::Monitor.new
      @children = {}
      @assignments = []
      @owner_pid = nil
      @stopping = false
      @shutdown_requested = false
      @quieted = false
      @last_memory_check = 0
      @signal_read = nil
      @signal_write = nil
      @respawn_backoff = Backoff.new(base: RESPAWN_BACKOFF)
      @restart = build_restart
    end

    # `install_signals:` is false in tests so the integration suite can
    # drive `shutdown` / `rolling_restart` directly without poisoning the
    # test process's signal handlers.
    #
    # Traps go in BEFORE fork_children: a TERM landing in the (previously
    # post-fork) window between fork and trap installation left the parent on
    # its default disposition — it died instantly and orphaned live, fetching
    # children. Installed first, the trap queues the TERM and the supervise
    # loop drains it (relaying to children) even if it arrives mid-boot.
    def boot(install_signals: true)
      raise 'Wurk::Swarm already booted' unless @assignments.empty?
      raise ArgumentError, 'Topology has no slots' if @topology.empty?

      @assignments = @topology.assignments.freeze
      @owner_pid = ::Process.pid
      install_signal_handlers if install_signals
      close_parent_sockets
      fork_children
      child_pids
    end

    # A snapshot, not the live table. Callers read this off the supervise
    # thread, which inserts (respawn, restart) and deletes (reap) on every tick;
    # handing out the live Hash lets them iterate it mid-mutation.
    def children
      @lock.synchronize { @children.dup }
    end

    def supervise
      return unless owner?

      until done?
        drain_signals
        shutdown if @shutdown_requested && !@stopping
        reap_children
        spawn_due_respawns
        advance_restart unless @stopping
        check_memory_pressure
        sleep SUPERVISE_TICK
      end
    end

    def shutdown(timeout: @shutdown_timeout)
      return unless owner?

      @stopping = true
      @lock.synchronize { @restart.abort }
      relay_signal('TERM')
      wait_for_children(timeout + SHUTDOWN_GRACE)
      hard_kill_stragglers
      close_signal_pipe
    end

    # Cross-thread drain request: raise a flag the supervise loop observes on
    # its next tick instead of draining on the caller's thread. `shutdown`
    # walks and clears the child table that the supervise thread is
    # concurrently mutating (reap, respawn, restart), so two threads inside it
    # race. Every caller that isn't the supervise thread — rails_boot's
    # `at_exit`, which fires on the host's main thread — comes through here.
    def request_shutdown
      @shutdown_requested = true
    end

    # Only the process that forked the children may supervise or signal them.
    # A forked child inherits this object along with the host's `at_exit` hooks
    # — and rails_boot registers one that drains the swarm — so ChildBoot's
    # `exit` reaches a full drain inside the child. There `@children` holds the
    # child's SIBLINGS, not its own children: unguarded, that TERMs them, stalls
    # the whole shutdown timeout waiting on PIDs it can never reap, then SIGKILLs
    # whatever survived.
    def owner?
      ::Process.pid == @owner_pid
    end

    # TSTP quiet is one-way and GLOBAL (spec §21.3): it must survive respawns
    # and memory recycles, or a quieted-but-crashed child's replacement would
    # resume fetching mid-maintenance. The flag makes every future fork boot
    # already-quieted (see ChildBoot start_quiet).
    def quiet_swarm
      @quieted = true
      relay_signal('TSTP')
    end

    # SIGUSR1: queue every live child for the rolling-restart state machine,
    # which replaces one slot at a time (spawn replacement → await its
    # heartbeat → TERM the old child → await its drain) without blocking the
    # supervise thread, so TERM stays responsive throughout the cycle.
    def rolling_restart
      @lock.synchronize { @restart.enqueue(@children.keys) }
    end

    private

    def advance_restart
      @lock.synchronize { @restart.advance }
    end

    def child_pids
      @lock.synchronize { @children.keys }
    end

    def child_meta(pid)
      @lock.synchronize { @children[pid] }
    end

    def any_children?
      @lock.synchronize { !@children.empty? }
    end

    def build_restart
      Restart.new(Restart::Config.new(
                    spawn: method(:spawn_child),
                    kill: method(:safe_kill),
                    heartbeat: method(:heartbeat_seen?),
                    describe: ->(pid) { child_meta(pid) },
                    now: method(:monotonic),
                    logger: logger,
                    heartbeat_wait: HEARTBEAT_WAIT,
                    drain_timeout: @shutdown_timeout + SHUTDOWN_GRACE,
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
      @lock.synchronize { @children[pid] = { slot: slot, index: idx, spawned_at: monotonic } }
      pid
    end

    # Capture the parent PID BEFORE forking and hand it to the child: read
    # from the parent, it is race-free even if the parent dies the instant
    # after fork (getppid in the child could already return the reaper). The
    # child's OrphanGuard compares live getppid against it.
    def fork_child(slot, idx)
      parent_pid = ::Process.pid
      pid = ::Process.fork
      return pid if pid

      # Drop the parent's self-pipe first: the inherited traps still write to
      # it, so a signal landing in the window before ChildBoot resets them
      # would surface in the PARENT's supervise loop (an operator TERMing one
      # child pid would drain the whole swarm). Dropped, the trap write no-ops.
      close_signal_pipe
      ChildBoot.new(@config, slot, idx, parent_pid: parent_pid, start_quiet: @quieted).run
      exit 0 # unreachable; ChildBoot exits explicitly
    end

    # Self-pipe pattern (same as Wurk::CLI): the trap only writes the signal
    # name to a pipe — no Thread::Queue#push, which takes a mutex a trap can
    # deadlock against. The supervise loop polls the read end each tick.
    def install_signal_handlers
      @signal_read, @signal_write = ::IO.pipe
      SWARM_SIGNALS.each_key do |sig|
        ::Signal.trap(sig) { emit_signal(sig) }
      rescue ArgumentError
        # Platform without this signal (e.g. some JRuby builds) — skip it.
        nil
      end
    end

    # Both FDs, once. The traps stay installed and keep firing after a drain, so
    # clear the ivars BEFORE closing: `emit_signal` then writes to nothing
    # instead of a dead FD, and a `drain_signals` loop mid-tick (TERM handled,
    # asking for the next buffered signal) stops instead of reading a closed
    # pipe. Called on shutdown and, in the child, immediately after fork.
    def close_signal_pipe
      read = @signal_read
      write = @signal_write
      @signal_read = @signal_write = nil
      read&.close
      write&.close
    end

    # Non-blocking self-pipe write from trap context: a blocking `puts` could
    # stall signal delivery if the pipe fills. `exception: false` returns
    # :wait_writable instead of raising when full (drop the coalescible
    # duplicate); a closed pipe during shutdown is ignored too.
    def emit_signal(sig)
      @signal_write&.write_nonblock("#{sig}\n", exception: false)
    rescue ::IOError, ::Errno::EPIPE, ::Errno::EBADF
      nil
    end

    def drain_signals
      return unless @signal_read

      while (sig = read_pending_signal)
        case SWARM_SIGNALS[sig]
        when :term then shutdown
        when :tstp then quiet_swarm
        when :usr1 then rolling_restart
        when :usr2
          reopen_logs
          relay_signal('USR2')
        end
      end
    end

    # One buffered line per pending signal, non-blocking (wait_readable(0)).
    # nil once the pipe is drained, ending the loop for this tick. Reads through
    # a local because the pipe can vanish mid-drain: a buffered TERM runs
    # `shutdown`, which closes it, and the loop then asks for the next signal.
    def read_pending_signal
      read = @signal_read
      return nil unless read&.wait_readable(0)

      read.gets&.strip
    end

    def reopen_logs
      log = @config.logger
      log.reopen if log.respond_to?(:reopen)
    rescue StandardError
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
      @lock.synchronize do
        meta = @children.delete(pid)
        return unless meta
        return if @restart.claim_exit(pid)

        if @stopping
          logger.info { "swarm: child #{pid} exited (status=#{status.exitstatus})" }
        else
          schedule_respawn(pid, status, meta)
        end
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

        respawn_slot(idx)
      end
    end

    # Consume the backoff only after the fork lands. A fork/resource failure
    # (EAGAIN, ENOMEM) must neither drop the pending respawn nor escape the
    # supervise loop: on failure we re-arm the backoff and leave the slot
    # pending so the next due tick retries instead of hot-looping.
    def respawn_slot(idx)
      spawn_child(@assignments[idx], idx)
      @respawn_backoff.consume(idx)
    rescue StandardError => e
      delay = @respawn_backoff.fail(idx)
      logger.warn { "swarm: respawn of slot #{idx} failed (#{e.class}: #{e.message}); retrying in #{delay}s" }
    end

    def check_memory_pressure
      return unless @memory_limit

      now = monotonic
      return if now - @last_memory_check < MEMORY_CHECK_INTERVAL

      @last_memory_check = now
      child_pids.each { |pid| recycle_if_bloated(pid) }
    end

    # Route a bloated child through the restart state machine (same path as a
    # rolling restart) so recycle is graceful — a healthy replacement takes over
    # before the old child is TERMed — and can't overlap a restart already in
    # flight on the slot.
    def recycle_if_bloated(pid)
      rss = pid_rss_kb(pid)
      return if rss.nil? || rss < @memory_limit

      logger.warn { "swarm: child #{pid} RSS #{rss}KB >= #{@memory_limit}KB; recycling" }
      @lock.synchronize { @restart.enqueue([pid]) }
    end

    def pid_rss_kb(pid)
      return nil unless ::File.exist?("/proc/#{pid}/statm")

      ::File.read("/proc/#{pid}/statm").split[1].to_i * 4
    rescue StandardError
      nil
    end

    def relay_signal(sig)
      child_pids.each { |pid| safe_kill(pid, sig) }
    end

    # The one place the supervisor signals a child: relay_signal,
    # hard_kill_stragglers and the restart machine's `kill:` callback all funnel
    # through here, so the owner check covers every path at a single choke point.
    def safe_kill(pid, sig)
      return unless owner?

      ::Process.kill(sig, pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def wait_for_children(timeout)
      deadline = monotonic + timeout
      while monotonic < deadline && any_children?
        reap_children
        sleep 0.1
      end
    end

    # Kill and forget atomically: a child landing in the table between the walk
    # and the clear would be dropped from it without ever being signalled —
    # untracked and still alive.
    def hard_kill_stragglers
      @lock.synchronize do
        @children.each_key { |pid| safe_kill(pid, 'KILL') }
        @children.clear
      end
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
      @stopping && !any_children?
    end
  end
end
