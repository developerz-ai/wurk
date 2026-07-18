# frozen_string_literal: true

module Wurk
  class Swarm
    # Orphan protection for a swarm child. A SIGKILL'd (or crashed, or OOM'd)
    # supervisor leaves its children with no parent — they keep fetching
    # forever, and the next redeploy that boots a fresh supervisor then runs
    # doubled concurrency against the same queues. This arms two independent
    # mechanisms so a child self-terminates the moment it is orphaned:
    #
    #   * Linux: PR_SET_PDEATHSIG delivers SIGTERM the instant the forking
    #     thread dies (kernel-level, zero latency). It is set right after the
    #     fork; the fork race — the parent can die in the window before the
    #     syscall lands, so the signal is never queued — is closed by the
    #     watchdog's immediate getppid check below.
    #   * Everywhere: a watchdog thread compares getppid against the PID the
    #     parent captured *before* forking (race-free — never the reaper PID).
    #     On its first tick, and every `interval` seconds after, a mismatch
    #     means the parent is gone. This is the only mechanism on non-Linux
    #     (JRuby, macOS dev) and a backstop for pdeathsig's per-thread caveat.
    #
    # Both funnel through the child's own SIGTERM handler (Process.kill self),
    # so orphan death is an ordinary graceful drain — in-flight jobs finish and
    # the private list is requeued — not a hard kill.
    class OrphanGuard
      WATCHDOG_INTERVAL = 5
      # <linux/prctl.h>: PR_SET_PDEATHSIG is option 1.
      PR_SET_PDEATHSIG = 1

      # pdeathsig via libc/prctl is Linux-only. Off elsewhere; the watchdog
      # thread covers those platforms on its own.
      def self.pdeathsig_supported?
        ::RbConfig::CONFIG['host_os'].include?('linux')
      end

      # `on_orphan` is injectable so unit tests can observe the trip without
      # actually signalling the test process. Production leaves it nil and
      # self-TERMs, routing through the child's normal graceful-drain handler.
      def initialize(parent_pid, logger:, interval: WATCHDOG_INTERVAL,
                     pdeathsig: pdeathsig_supported?, on_orphan: nil)
        @parent_pid = parent_pid
        @logger = logger
        @interval = interval
        @pdeathsig = pdeathsig
        @on_orphan = on_orphan || -> { ::Process.kill('TERM', ::Process.pid) }
      end

      # Arm both mechanisms. Returns the watchdog thread so the caller can
      # retain it (otherwise GC could reap it).
      def arm
        set_pdeathsig
        start_watchdog
      end

      def orphaned?
        ::Process.ppid != @parent_pid
      end

      private

      def pdeathsig_supported?
        self.class.pdeathsig_supported?
      end

      # `sleep until orphaned?` checks first, so an already-orphaned child
      # (the pdeathsig fork race) drains on the very first tick with no wait.
      def start_watchdog
        ::Thread.new do
          ::Thread.current.name = 'wurk-orphan-watchdog'
          ::Thread.current.report_on_exception = false
          sleep @interval until orphaned?
          drain
        end
      end

      def drain
        @logger&.warn { "swarm child #{::Process.pid}: parent #{@parent_pid} gone; draining orphan" }
        @on_orphan.call
      rescue StandardError => e
        @logger&.error { "swarm child #{::Process.pid}: orphan drain failed: #{e.class}: #{e.message}" }
      end

      def set_pdeathsig
        return unless @pdeathsig

        arm_pdeathsig
      rescue ::StandardError, ::LoadError => e
        @logger&.debug { "swarm child #{::Process.pid}: PR_SET_PDEATHSIG unavailable (#{e.class}: #{e.message})" }
      end

      # prctl(int option, unsigned long arg2, …) — option is int, the rest are
      # unsigned long. Fiddle opens the already-loaded libc (dlopen nil).
      def arm_pdeathsig
        require 'fiddle'
        libc = ::Fiddle.dlopen(nil)
        func = ::Fiddle::Function.new(
          libc['prctl'],
          [::Fiddle::TYPE_INT, ::Fiddle::TYPE_LONG, ::Fiddle::TYPE_LONG, ::Fiddle::TYPE_LONG, ::Fiddle::TYPE_LONG],
          ::Fiddle::TYPE_INT
        )
        func.call(PR_SET_PDEATHSIG, ::Signal.list.fetch('TERM'), 0, 0, 0)
      end
    end
  end
end
