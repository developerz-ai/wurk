# frozen_string_literal: true

require_relative '../launcher'
require_relative '../fetcher/reliable'

module Wurk
  class Swarm
    # Step 5 of the boot ordering. Runs inside each forked child:
    #   * reset signal traps inherited from the parent,
    #   * reconnect ActiveRecord (if loaded) + open a fresh Redis pool,
    #   * apply the slot's queues + concurrency to the default capsule,
    #   * install child signal handlers (TERM/INT drain, TSTP quiet,
    #     USR2 reopen logs),
    #   * launch the Wurk::Launcher and block until shutdown.
    #
    # Kept separate from Wurk::Swarm so the parent supervisor stays
    # focused on PID supervision (SRP).
    class ChildBoot
      CHILD_SIGNALS = { 'TERM' => :term, 'INT' => :term, 'TSTP' => :tstp, 'USR2' => :usr2 }.freeze

      def initialize(config, slot, index)
        @config = config
        @slot = slot
        @index = index
        @signal_queue = ::Thread::Queue.new
      end

      def run
        reset_inherited_signals
        reconnect_after_fork
        Wurk.server = true
        apply_slot_to_config
        launcher = Wurk::Launcher.new(@config)
        install_signal_handlers(launcher)
        launcher.run
        wait_loop(launcher)
        exit 0
      rescue StandardError, ::Wurk::Shutdown => e
        @config.logger.error { "swarm child ##{@index} (#{::Process.pid}) crashed: #{e.class}: #{e.message}" }
        exit 1
      end

      private

      # Parent installed traps for TERM/INT/TSTP/CONT/USR1 — the child
      # needs its own behavior, not the parent's.
      def reset_inherited_signals
        %w[TERM INT TSTP CONT USR1 USR2].each { |s| ::Signal.trap(s, 'DEFAULT') }
      end

      def reconnect_after_fork
        @config.reset_redis_pools! if @config.respond_to?(:reset_redis_pools!)
        return unless defined?(::ActiveRecord::Base)

        begin
          ::ActiveRecord::Base.establish_connection
        rescue StandardError
          nil
        end
      end

      def apply_slot_to_config
        cap = @config.default_capsule
        cap.queues = @slot.queues
        cap.concurrency = @slot.concurrency
        cap.fetcher = Wurk::Fetcher::Reliable.new(cap)
        # Configuration#freeze! (called by Launcher#run) freezes every
        # capsule. Capsule's `redis_pool`, `local_redis_pool`,
        # `server_middleware`, and `client_middleware` lazy-init their
        # ivars via `||=` — that mutation would FrozenError after
        # freeze, the first time the processor hit them. Materialize
        # them now so the post-freeze code paths only read.
        cap.redis_pool
        cap.local_redis_pool
        cap.client_middleware
        cap.server_middleware
      end

      def install_signal_handlers(launcher)
        CHILD_SIGNALS.each { |sig, sym| ::Signal.trap(sig) { @signal_queue << sym } }
        Thread.new { dispatch_signals(launcher) }
      end

      # Drains the queue forever; launcher.stop is the exit condition
      # (the wait_loop watches launcher.stopping?). TERM/INT both trigger
      # the stop sequence; subsequent signals are no-ops once stopped.
      def dispatch_signals(launcher)
        loop do
          case @signal_queue.pop
          when :term then launcher.stop
          when :tstp then launcher.quiet
          when :usr2 then reopen_logs
          end
        end
      end

      def reopen_logs
        log = @config.logger
        log.reopen if log.respond_to?(:reopen)
      rescue StandardError
        nil
      end

      def wait_loop(launcher)
        sleep 0.5 until launcher.stopping?
      end
    end
  end
end
