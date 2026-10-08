# frozen_string_literal: true

require_relative '../component'
require_relative '../launcher'
require_relative '../client/buffered'
require_relative '../fetcher/reliable'
require_relative '../lua'
require_relative '../health'
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

      # TTIN is trapped because its default disposition STOPS the process: an
      # operator's `kill -TTIN <child>` asking for a thread dump would suspend
      # the worker instead.
      CHILD_SIGNALS = { 'TERM' => :term, 'INT' => :term, 'TSTP' => :tstp, 'USR2' => :usr2, 'TTIN' => :ttin }.freeze

      # `parent_pid` is captured by the swarm before it forks (race-free) and
      # threaded through so OrphanGuard can tell "still supervised" from
      # "reparented after the supervisor died". Defaults to the live parent for
      # the non-swarm callers (tests) that construct a ChildBoot directly.
      # `start_quiet:` — the swarm was TSTP-quieted before this child was
      # forked (respawn/recycle during maintenance); boot the launcher already
      # quieted so the replacement doesn't resume fetching. Delivered as a
      # constructor flag, not a post-fork TSTP: a signal landing before this
      # child resets its traps hits the parent's inherited (inert) handler and
      # is dropped — the supervisor's TSTP re-relay is only the backstop.
      # `fleet_size:` — slots in the swarm's topology, published to
      # Health.fleet_size so this child's health listener (if it wins the
      # port) can judge /ready on the whole swarm, not just itself.
      def initialize(config, slot, index, parent_pid: ::Process.ppid, start_quiet: false, fleet_size: nil)
        @config = config
        @slot = slot
        @index = index
        @fleet_size = fleet_size
        @parent_pid = parent_pid
        @start_quiet = start_quiet
        @signal_read = nil
        @signal_write = nil
        @pending_tstp = false
      end

      def run
        reset_inherited_signals
        reconnect_after_fork
        Wurk.server = true
        Wurk::Health.fleet_size = @fleet_size
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

      # Boot the launcher and block until shutdown. Joining the signal-dispatch
      # thread means the child can't fall through to `exit 0` mid-drain. Orphan
      # protection is armed right AFTER launcher.run — the TERM handler is in
      # place (so pdeathsig / the watchdog drain gracefully) and the managers
      # are up (so a self-TERM can't race launcher.run). A parent that died
      # during boot is still caught immediately: the watchdog's first getppid
      # check sees the reparent and drains at once.
      def run_launcher
        launcher = Wurk::Launcher.new(@config)
        install_signal_handlers(launcher)
        # K23: a TERM that landed between trap install and this call would,
        # absent the shutdown gate, have its drain finish — after which `run`
        # boots anyway and leaves a launcher nobody ever asked to stop. The
        # gate inside Launcher#run is the single claim for the boot, so this
        # order (install child traps → call run) is the contract.
        launcher.run
        launcher.quiet if @start_quiet
        arm_orphan_guard
        @dispatcher.join
      end

      def arm_orphan_guard
        @orphan_guard = OrphanGuard.new(@parent_pid, logger: @config.logger)
        @watchdog = @orphan_guard.arm
      end

      # Parent installed traps for TERM/INT/TSTP — the child needs its own
      # behavior, not the parent's. USR2 too: the child owns log-reopen.
      #
      # TSTP is the exception to DEFAULT: its default disposition is a kernel
      # stop, and the boot window (reconnect, `:fork` / `:startup` hooks) runs
      # before install_signal_handlers. A relayed quiet landing there would
      # SUSPEND the child — a stopped worker holding its slot — so it is
      # recorded instead and replayed once the real handler is in place. A
      # bare ivar write is all a trap may safely do here.
      def reset_inherited_signals
        %w[TERM INT USR2].each { |s| ::Signal.trap(s, 'DEFAULT') }
        ::Signal.trap('TSTP') { @pending_tstp = true }
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
        # The reliable_push outage buffer, its drainer thread and its mutexes
        # are process-global and were copied wholesale from the parent. The
        # Process._fork hook normally beats us to it (making this a no-op) —
        # the explicit call keeps the swarm path deterministic and ordered
        # after the pool reset, so a re-armed drainer can only ever see the
        # child's own pool.
        Wurk::Client::Buffered.reset_after_fork!
        validate_redis!
        reconnect_active_record
        # The dogstatsd client is memoized at the class level (Statsd.client),
        # so without a reset every child would share the parent's UDP socket
        # and thread-locals instead of building its own after fork.
        Wurk::Metrics::Statsd.reset!
      end

      # Prove the child's fresh Redis socket reaches a live server before it
      # starts fetching, through RedisPool#with, which owns the retry+backoff
      # (production incident #101), so a transient blip during boot rides out
      # instead of racing straight into a dead pool. A check that still fails
      # past the wrapper's retries propagates and crashes the child (the swarm
      # respawns it) rather than booting a worker that can't reach Redis.
      #
      # The probe is the Lua cache check itself (Loader.load_missing): its
      # `SCRIPT EXISTS` round trip proves the socket as well as a PING would,
      # and against a warm server cache it is the only round trip. Idempotent
      # (SCRIPT LOAD is), so a cold cache's second trip may be replayed too.
      #
      # #101 boot-audit: hoisting the upload into the parent (one server-global
      # `SCRIPT LOAD` for the whole fleet) was measured and REJECTED — see
      # Swarm#boot. Children reconnect in parallel, so the check they pay here
      # overlaps; the parent's would have been serial, ahead of every fork.
      def validate_redis!
        @config.redis_pool.with(idempotent: true) { |conn| Wurk::Lua::Loader.load_missing(conn) }
      end

      # AR reconnect is best-effort — a Redis-only worker with no database still
      # runs — but the silent `rescue nil` here hid a real misconfiguration
      # during the #101 audit, so warn loudly instead of swallowing.
      #
      # #101 boot-audit: measured, not assumed. `establish_connection` only
      # records the connection spec on the pool manager (~0.3ms warm, on top
      # of a one-time adapter-load cost already paid pre-fork in the parent);
      # it does not itself open a socket. `ConnectionPool#stat[:connections]`
      # stays 0 immediately after — AR opens the real handshake lazily, on
      # the job thread's first `ActiveRecord::Base.connection` checkout, same
      # as it always has. So `:startup` (fired right after this in `#run`)
      # never waits on a DB round trip. Pinned by
      # `test_reconnect_active_record_does_not_eagerly_open_a_connection`.
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
        emit_signal('TSTP') if @pending_tstp
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
      # (which blocks on manager drain) and then return — run_launcher
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
          when :ttin then launcher.dump_threads
          end
        end
      end

      def reopen_logs
        log = @config.logger
        log.reopen if log.respond_to?(:reopen)
      rescue StandardError
        nil
      end
    end
  end
end
