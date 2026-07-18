# frozen_string_literal: true

require_relative '../component'
require_relative '../launcher'
require_relative '../fetcher/reliable'
require_relative '../lua'
require_relative 'orphan_guard'

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

      # `parent_pid` is captured by the swarm before it forks (race-free) and
      # threaded through so OrphanGuard can tell "still supervised" from
      # "reparented after the supervisor died". Defaults to the live parent for
      # the non-swarm callers (tests) that construct a ChildBoot directly.
      def initialize(config, slot, index, parent_pid: ::Process.ppid)
        @config = config
        @slot = slot
        @index = index
        @parent_pid = parent_pid
        @signal_read = nil
        @signal_write = nil
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
      # mid-drain. Orphan protection is armed right AFTER launcher.run — the
      # TERM handler is in place (so pdeathsig / the watchdog drain gracefully)
      # and the managers are up (so a self-TERM can't race launcher.run). A
      # parent that died during boot is still caught immediately: the watchdog's
      # first getppid check sees the reparent and drains at once.
      def run_launcher
        launcher = Wurk::Launcher.new(@config)
        install_signal_handlers(launcher)
        launcher.run
        arm_orphan_guard
        wait_loop(launcher)
      end

      def arm_orphan_guard
        @orphan_guard = OrphanGuard.new(@parent_pid, logger: @config.logger)
        @watchdog = @orphan_guard.arm
      end

      # Parent installed traps for TERM/INT/TSTP — the child needs its own
      # behavior, not the parent's. USR2 too: the child owns log-reopen.
      # USR1 (rolling restart) is a no-op in the child — trap it with a log
      # so stray USR1s don't trigger default termination.
      def reset_inherited_signals
        %w[TERM INT TSTP USR2].each { |s| ::Signal.trap(s, 'DEFAULT') }
        # A genuine no-op in the child (rolling restart is the parent's job) —
        # trap it empty so a stray USR1 can't fall through to default
        # termination. Must NOT log: Logger synchronizes writes and would
        # deadlock if the trap fired mid-write.
        ::Signal.trap('USR1') { nil }
      rescue ArgumentError
        nil
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

      # Self-pipe pattern (same as Wurk::CLI / Wurk::Swarm): the trap only
      # writes the signal name to a pipe — never Thread::Queue#push, whose
      # mutex a trap can deadlock against.
      def install_signal_handlers(launcher)
        @signal_read, @signal_write = ::IO.pipe
        CHILD_SIGNALS.each_key do |sig|
          ::Signal.trap(sig) { emit_signal(sig) }
        rescue ArgumentError
          nil
        end
        @dispatcher = Thread.new { dispatch_signals(launcher) }
      end

      # Non-blocking self-pipe write from trap context: a blocking `puts` could
      # stall the TERM drain if the pipe ever filled. `exception: false` returns
      # :wait_writable instead of raising when full (the queued duplicate
      # coalesces); a closed pipe during shutdown is ignored too.
      def emit_signal(sig)
        @signal_write.write_nonblock("#{sig}\n", exception: false)
      rescue ::IOError, ::Errno::EPIPE, ::Errno::EBADF
        nil
      end

      # TSTP/USR2 keep looping; TERM/INT run the full launcher.stop
      # (which blocks on manager drain) and then return — wait_loop
      # joins this thread, so the main child thread can't `exit 0`
      # mid-drain. Otherwise quiet would flip launcher.stopping? true
      # and the main thread would race past the unfinished managers.
      def dispatch_signals(launcher)
        loop do
          @signal_read.wait_readable
          sig = @signal_read.gets&.strip
          break if sig.nil?

          case CHILD_SIGNALS[sig]
          when :term
            launcher.stop
            break
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
