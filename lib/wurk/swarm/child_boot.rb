# frozen_string_literal: true

require_relative '../component'
require_relative '../launcher'
require_relative '../fetcher/reliable'
require_relative '../lua'

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
      include Component

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
        # :fork runs in each child after our internal AR/Redis reconnect and
        # before fetching, so apps can reopen sockets / restart threads /
        # reconnect non-fork-safe libs (Ent §7.4). It never fires in the parent
        # (which only forks + supervises). Like :startup, the child's forked
        # copy of the bucket is cleared after dispatch, so siblings fire theirs.
        fire_event(:fork)
        apply_slot_to_config
        # :startup must fire in each worker child before its managers spin up
        # (Sidekiq contract, reraise: true). The parent supervisor never runs
        # jobs, so the non-swarm CLI path fires it once per process — for the
        # swarm, each child fires it here. Its own forked copy of the bucket is
        # cleared after, so siblings still fire their own.
        fire_event(:startup, reraise: true)
        run_launcher
        exit 0
      rescue StandardError, ::Wurk::Shutdown => e
        @config.logger.error { "swarm child ##{@index} (#{::Process.pid}) crashed: #{e.class}: #{e.message}" }
        exit 1
      end

      private

      # Boot the launcher and block until shutdown. wait_loop joins the
      # signal-dispatch thread, so the child can't fall through to `exit 0`
      # mid-drain.
      def run_launcher
        launcher = Wurk::Launcher.new(@config)
        install_signal_handlers(launcher)
        launcher.run
        wait_loop(launcher)
      end

      # Parent installed traps for TERM/INT/TSTP/USR1 — the child needs its own
      # behavior, not the parent's. USR2 too: the child owns log-reopen.
      def reset_inherited_signals
        %w[TERM INT TSTP USR1 USR2].each { |s| ::Signal.trap(s, 'DEFAULT') }
      end

      def reconnect_after_fork
        @config.reset_redis_pools!
        validate_redis!
        reconnect_active_record
      end

      # Prove the child's fresh Redis socket reaches a live server before it
      # starts fetching: one PING through RedisPool#with, which owns the
      # retry+backoff (production incident #101), so a transient blip during
      # boot rides out instead of racing straight into a dead pool. A PING that
      # still fails past the wrapper's retries propagates and crashes the child
      # (the swarm respawns it) rather than booting a worker that can't reach
      # Redis. The same checkout eagerly primes every Lua script in one
      # pipelined round-trip so the first EVALSHA hits a warm cache.
      def validate_redis!
        @config.redis_pool.with do |conn|
          conn.call('PING')
          Wurk::Lua::Loader.script_load_all(conn)
        end
      end

      # AR reconnect is best-effort — a Redis-only worker with no database still
      # runs — but the silent `rescue nil` here hid a real misconfiguration
      # during the #101 audit, so warn loudly instead of swallowing.
      def reconnect_active_record
        return unless defined?(::ActiveRecord::Base)

        ::ActiveRecord::Base.establish_connection
      rescue StandardError => e
        @config.logger.warn do
          "swarm child ##{@index} (#{::Process.pid}) ActiveRecord reconnect failed: #{e.class}: #{e.message}"
        end
      end

      def apply_slot_to_config
        cap = @config.default_capsule
        cap.queues = @slot.queues
        cap.concurrency = @slot.concurrency
        # Fetcher defaulting + lazy-ivar materialization now happens in
        # Configuration#freeze! (Capsule#prepare!), called by Launcher#run
        # below — for every entry point, not just the swarm.
      end

      def install_signal_handlers(launcher)
        CHILD_SIGNALS.each { |sig, sym| ::Signal.trap(sig) { @signal_queue << sym } }
        @dispatcher = Thread.new { dispatch_signals(launcher) }
      end

      # TSTP/USR2 keep looping; TERM/INT run the full launcher.stop
      # (which blocks on manager drain) and then return — wait_loop
      # joins this thread, so the main child thread can't `exit 0`
      # mid-drain. Otherwise quiet would flip launcher.stopping? true
      # and the main thread would race past the unfinished managers.
      def dispatch_signals(launcher)
        loop do
          case @signal_queue.pop
          when :term
            launcher.stop
            return
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

      def wait_loop(_launcher)
        @dispatcher.join
      end
    end
  end
end
