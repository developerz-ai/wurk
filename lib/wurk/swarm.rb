# frozen_string_literal: true

require_relative 'component'
require_relative 'launcher'
require_relative 'fetcher/reliable'
require_relative 'keys'
require_relative 'swarm/child_boot'

module Wurk
  # Parent supervisor. Forks N children per the worker topology, monitors
  # PIDs, relays signals, respawns crashed children, handles rolling
  # restart on SIGUSR1, recycles RSS-bloated children.
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
  #   TERM/INT  → `shutdown`           (graceful drain)
  #   TSTP      → relay TSTP           (pause fetch)
  #   CONT      → relay CONT           (resume fetch)
  #   USR1      → `rolling_restart`    (zero-downtime cycle)
  class Swarm
    include Component

    SUPERVISE_TICK = 0.2
    RESPAWN_BACKOFF = 1.0
    HEARTBEAT_WAIT = 30
    MEMORY_CHECK_INTERVAL = 10
    DEFAULT_SHUTDOWN_TIMEOUT = 25

    attr_reader :topology, :children

    def initialize(topology:, config: Wurk.configuration, memory_limit: nil,
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
        reap_one_child
        check_memory_pressure
        sleep SUPERVISE_TICK
      end
    end

    def shutdown(timeout: @shutdown_timeout)
      @stopping = true
      relay_signal('TERM')
      wait_for_children(timeout)
      hard_kill_stragglers
    end

    # SIGUSR1. For each existing child, fork a replacement, wait for its
    # first heartbeat, then TERM + drain the old one. Long-running jobs
    # in the old slot get the full shutdown_timeout while the replacement
    # is already serving new work.
    def rolling_restart
      @children.dup.each do |old_pid, meta|
        replacement = fork_child(meta[:slot], meta[:index])
        @children[replacement] = meta
        wait_for_heartbeat(replacement)
        safe_kill(old_pid, 'TERM')
        wait_pid(old_pid, @shutdown_timeout)
        @children.delete(old_pid)
      end
    end

    private

    # Step 3.
    def close_parent_sockets
      @config.reset_redis_pools! if @config.respond_to?(:reset_redis_pools!)
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
      @assignments.each_with_index do |slot, idx|
        @children[fork_child(slot, idx)] = { slot: slot, index: idx }
      end
    end

    def fork_child(slot, idx)
      pid = ::Process.fork
      return pid if pid

      ChildBoot.new(@config, slot, idx).run
      exit 0 # unreachable; ChildBoot exits explicitly
    end

    def install_signal_handlers
      { 'TERM' => :term, 'INT' => :term, 'TSTP' => :tstp,
        'CONT' => :cont, 'USR1' => :usr1 }.each do |sig, sym|
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
        when :cont then relay_signal('CONT')
        when :usr1 then rolling_restart
        end
      end
    end

    def next_signal_symbol
      @signal_queue.pop(true)
    rescue ThreadError
      nil
    end

    def reap_one_child
      pid, status = ::Process.wait2(-1, ::Process::WNOHANG)
      on_child_exit(pid, status) if pid
    rescue Errno::ECHILD
      @stopping = true
    end

    def on_child_exit(pid, status)
      meta = @children.delete(pid)
      return unless meta

      if @stopping
        logger.info { "swarm: child #{pid} exited (status=#{status.exitstatus})" }
      else
        logger.warn { "swarm: child #{pid} died (status=#{status.exitstatus}); respawning slot #{meta[:index]}" }
        sleep RESPAWN_BACKOFF
        @children[fork_child(meta[:slot], meta[:index])] = meta
      end
    end

    def check_memory_pressure
      return unless @memory_limit

      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      return if now - @last_memory_check < MEMORY_CHECK_INTERVAL

      @last_memory_check = now
      @children.dup.each_key { |pid| recycle_if_bloated(pid) }
    end

    def recycle_if_bloated(pid)
      rss = pid_rss_kb(pid)
      return if rss.nil? || rss < @memory_limit

      logger.warn { "swarm: child #{pid} RSS #{rss}KB >= #{@memory_limit}KB; recycling" }
      safe_kill(pid, 'TERM')
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

    def wait_pid(pid, timeout)
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
      while ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) < deadline
        return true if ::Process.wait(pid, ::Process::WNOHANG)

        sleep 0.1
      end
      false
    rescue Errno::ECHILD
      true
    end

    def wait_for_children(timeout)
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
      while ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) < deadline && @children.any?
        reap_one_child
        sleep 0.1
      end
    end

    def hard_kill_stragglers
      @children.each_key { |pid| safe_kill(pid, 'KILL') }
      @children.clear
    end

    # Identity is `<hostname>:<pid>:<nonce>`. PROCESS_NONCE is set when
    # Component loads in the parent and inherited by every fork — the
    # parent can compute a child's identity from its PID alone.
    # Returns true if the heartbeat was observed before the deadline.
    def wait_for_heartbeat(pid) # rubocop:disable Naming/PredicateMethod
      identity = "#{hostname}:#{pid}:#{Component::PROCESS_NONCE}"
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + HEARTBEAT_WAIT
      while ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) < deadline
        return true if @config.redis { |c| c.call('SISMEMBER', Keys::PROCESSES, identity) } == 1

        sleep 0.5
      end
      false
    end

    def done?
      @stopping && @children.empty?
    end
  end
end
