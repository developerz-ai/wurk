# frozen_string_literal: true

require_relative 'component'
require_relative 'manager'
require_relative 'processor'
require_relative 'heartbeat'
require_relative 'health'
require_relative 'keys'
require_relative 'scheduled'
require_relative 'leader'
require_relative 'cron'
require_relative 'metrics/rollup'
require_relative 'metrics/queue_rollup'
require_relative 'metrics/flusher'
require_relative 'history'
require_relative 'fetcher/reaper'
require_relative 'timer_loop'

module Wurk
  # Top-level supervisor inside each worker process. Owns the Manager pool
  # (one per Capsule), the scheduler poller, and the heartbeat thread.
  # The heartbeat WIRE lives in Wurk::Heartbeat — Launcher owns lifecycle,
  # signal dispatch, and stats rollup; Heartbeat owns the Redis writes.
  #
  # Lifecycle:
  #   * `run(async_beat:)` — freeze config, start heartbeat, poller, managers.
  #   * `quiet`            — stop fetching across all managers + poller.
  #   * `stop`             — graceful drain inside `config[:timeout]`.
  #   * `heartbeat`        — one-shot beat (also driven by the heartbeat thread).
  #
  # `flush_stats` rolls per-process Processor counters (PROCESSED / FAILURE
  # / EXPIRED) into the global + per-day Redis strings every beat. Per-day
  # keys carry `STATS_TTL` so old days expire automatically.
  #
  # Spec: docs/target/sidekiq-free.md §12 (Sidekiq::Launcher).
  class Launcher
    include Component

    # 5 years, in seconds. Per-day `stat:processed:YYYY-MM-DD` /
    # `stat:failed:YYYY-MM-DD` / `stat:expired:YYYY-MM-DD` strings carry
    # this TTL so they roll off without manual cleanup.
    STATS_TTL = 5 * 365 * 24 * 60 * 60

    # Re-exported for test/third-party callers that read it off Launcher
    # (Sidekiq's drop-in surface). The single source of truth is Heartbeat.
    BEAT_PAUSE = Heartbeat::BEAT_PAUSE

    # Bound on how long #stop waits for the boot-time reclaim sweep before
    # moving on — it can still be scanning a large keyspace when a fast
    # shutdown lands right after boot; teardown must not hang on it.
    BOOT_RECLAIM_JOIN_TIMEOUT = 5

    attr_accessor :managers, :poller, :cron_poller, :metrics_rollup, :queue_rollup, :metrics_flusher, :history

    def initialize(config, embedded: false)
      @config = config
      @embedded = embedded
      # @done is "quieted": stop fetching, stay alive, report quiet=true. It
      # deliberately does NOT stop the heartbeat — a quieted process that stopped
      # beating would never publish quiet=true and would expire out of the live
      # set (#236). Only #stop ends the beat, by terminating @beat_timer.
      @done = false
      @beat_timer = TimerLoop.new(BEAT_PAUSE)
      @managers = build_managers
      build_loops
      @leader = build_leader
      @reaper = build_reaper
      @health_server = build_health_server
      reset_thread_state
    end

    # Boot order matters:
    #   1. freeze! the config so mutations after fork are visible mistakes.
    #      A swarm child finds the slot-independent half already frozen by its
    #      parent (Configuration#prepare_for_fork!); what closes here is the
    #      capsules, which stayed open for this child's slot and pools.
    #   2. start the managers FIRST. They are the only thing here on the
    #      time-to-first-job path (the number bench/vs_sidekiq.rb measures);
    #      everything below is periodic background work whose first tick is
    #      seconds away, so it has nothing to gain from going ahead of them.
    #   3. spawn the heartbeat thread, so the dashboard sees the process
    #      right after it can pick up jobs.
    #   4. start the reaper and the boot-time reclaim sweep — kill-9 recovery,
    #      not decoration: a SIGKILLed sibling's in-flight jobs wait on this,
    #      so it stays ahead of the periodic loops.
    #   5. start the periodic loops. None of them ticks at zero — TimerLoop#run
    #      waits an interval before its first yield, Scheduled::Poller waits
    #      INITIAL_WAIT, and Leader waits DEFAULT_INITIAL_WAIT — so starting
    #      them last costs a few thread spawns and nothing else. Both leader-
    #      gated pollers are also safe to start before leadership settles: a
    #      non-leader tick just returns early.
    #   6. start the health probe server LAST so the listener doesn't
    #      accept k8s probes until the rest of the launcher is up.
    def run(async_beat: true)
      @started_at = Time.now.to_f
      # Default each capsule's fetcher + materialize its lazy pools/middleware
      # before the config freezes. Every entry point (swarm child, standalone
      # CLI, embedded) runs through here, so none boots with a nil fetcher.
      @config.capsules.each_value(&:prepare!)
      @config.freeze!
      @managers.each(&:start)
      @heartbeat_thread = safe_thread('heartbeat', &method(:start_heartbeat)) if async_beat
      @reaper.start
      # Run on a background thread so /ready probe isn't delayed by a large
      # orphan sweep (reaper.reclaim! is atomic, but can scan many entries).
      @boot_reclaim_thread = safe_thread('boot-reclaim', &method(:boot_reclaim))
      start_periodic_components
      @health_server&.start
    rescue StandardError
      # Boot is not atomic: whatever raised (a health-check port already bound,
      # ThreadError at the OS thread limit) leaves the steps before it holding
      # threads, sockets and a leader campaign — and the caller is about to drop
      # its only reference to us, so nothing else can ever release them. Guarded,
      # because the caller must see the boot failure, not a rollback failure.
      teardown_step('boot-rollback') { stop }
      raise
    end

    # Idempotent. Flips `stopping?` true, halts fetching across every
    # Manager + the poller, then fires the `:quiet` event in reverse
    # registration order so teardown hooks run LIFO.
    def quiet
      return if @done

      @done = true
      @managers.each(&:quiet)
      @poller&.terminate
      # The cron poller is intentionally NOT terminated here: a USR1-quieted
      # leader still enqueues periodic jobs — it only stops fetching for itself.
      # Loops stop only on full shutdown (#stop). Spec: sidekiq-ent.md §2.6.
      fire_event(:quiet, reverse: true)
    end

    # Graceful shutdown. Deadline is monotonic so wall-clock skew can't
    # extend it. Managers stop in parallel threads so a slow capsule
    # doesn't block its siblings — and each drain is guarded, because a
    # capsule that blows up mid-drain (Redis down during bulk_requeue) used
    # to surface out of `join` and skip the whole teardown tail, leaving the
    # leader lock held, the process listed as live, and its port open.
    def stop
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + (@config[:timeout] || 25)
      quiet
      stoppers = @managers.map { |m| Thread.new { teardown_step('manager') { m.stop(deadline) } } }
      fire_event(:shutdown, reverse: true)
      stoppers.each(&:join)
    ensure
      release_components
    end

    def stopping?
      @done
    end

    # One-shot beat. Public for embedded mode (and for tests) — the
    # heartbeat thread calls this on `BEAT_PAUSE` cadence.
    def heartbeat
      flush_stats
      beat
    end

    # Rolls in-process Processor counters into Redis. Pipelined so a single
    # round trip covers all writes. Skips when all counters are zero to
    # avoid touching keys we have nothing to add to.
    def flush_stats
      processed = Processor::PROCESSED.reset
      failed = Processor::FAILURE.reset
      expired = Processor::EXPIRED.reset
      return if processed.zero? && failed.zero? && expired.zero?

      write_stats(processed, failed, expired)
    rescue StandardError => e
      # The counters were reset above, so a raise here drops this window's stats
      # for good: #write_stats cannot claim apply-safety and the pool no longer
      # replays it through a blip. Accepted deliberately — adding them back
      # would double-count the case where the INCRBYs did land and only the
      # reply was lost, and the per-job at-least-once semantics don't apply to
      # *counters*. The next beat resets again.
      handle_exception(e, { context: 'flush_stats' })
    end

    # Used by tests to inspect the heartbeat thread; not part of the
    # Sidekiq public surface.
    attr_reader :heartbeat_thread

    private

    # Teardown tail, driven from #stop's ensure. Every release is guarded on
    # its own because they are independent: a Redis blip in one (leader CAS
    # release, heartbeat clear) must not strand the ones after it — the process
    # is exiting either way, so the only thing worse than a failed release is a
    # skipped one. Order matters twice over: full shutdown stops the periodic
    # loops (they survived #quiet) before the cluster lock is CAS-released, so
    # no tick races a follower's promotion, and the release itself happens on a
    # planned shutdown rather than waiting out the lock TTL.
    def release_components
      # Joined first, before anything below tears down the Redis pool it's
      # still reading from: it started as a fire-and-forget thread in #run
      # and a shutdown landing right after boot could otherwise race a
      # pool disconnect mid-scan. Bounded: a full-keyspace scan can outlast
      # the timeout, in which case the thread is left running rather than
      # blocking shutdown on it — #boot_reclaim already rescues and logs on
      # its own, so a straggler racing #reset_redis_pools! below just means
      # a noisy log line, not a hang.
      teardown_step('boot-reclaim-join') { @boot_reclaim_thread&.join(BOOT_RECLAIM_JOIN_TIMEOUT) }
      stop_periodic_components
      %i[stop_heartbeat clear_heartbeat].each { |step| teardown_step(step) { send(step) } }
      # Unguarded: fire_event already reports and skips past a raising hook.
      fire_event(:exit, reverse: true)
      # Embedded only: a swarm child or standalone process exits right after
      # #stop anyway, so disconnecting here would just make every unit test
      # that inspects Redis post-stop rebuild a pool for no reason. Embedded
      # hosts (Puma, a rake task) keep running and can `run` again later —
      # without this a stop-then-run cycle doubles the live socket set.
      teardown_step('redis-pools') { @config.reset_redis_pools! } if @embedded
    ensure
      # In an ensure of its own, not merely a guarded step: a leaked TCPServer
      # FD survives even a non-StandardError unwind (a second TERM landing
      # mid-teardown), and kubelet would keep getting 200s from a process that
      # is already gone.
      teardown_step('health-server') { @health_server&.stop }
    end

    # Mirror of #stop_periodic_components: every loop this process runs on a
    # timer, started in one place at the tail of #run. `compact` because the
    # history snapshotter is opt-in and an embedded boot may have stripped the
    # rest.
    def start_periodic_components
      [@poller, @leader, @cron_poller, @metrics_rollup,
       @queue_rollup, @metrics_flusher, @history].compact.each(&:start)
    end

    # Split out of #release_components to keep it under the AbcSize/
    # CyclomaticComplexity ceilings — these are the "periodic loop" releases,
    # independently guarded like everything else in the tail.
    #
    # The metrics flusher goes first: its #terminate drains the last window of
    # per-job counters into the `j|…` minute buckets, and Metrics::Rollup reads
    # exactly those buckets — stopping the rollup first would give its final
    # tick nothing to roll.
    def stop_periodic_components
      [@metrics_flusher, @cron_poller, @metrics_rollup, @queue_rollup,
       @history].each { |t| teardown_step(t.class) { t&.terminate } }
      teardown_step('reaper') { @reaper&.stop }
      teardown_step('leader') { @leader&.stop }
    end

    def teardown_step(label)
      yield
    rescue StandardError => e
      handle_exception(e, { context: "launcher-stop-#{label}" })
    end

    # INCRBY is additive, so a pipeline replayed after a lost reply counts this
    # window twice on every `stat:` key it touches — no apply-safety claim. (The
    # EXPIREs riding along are harmless to repeat; the INCRBYs pin the block.)
    def write_stats(processed, failed, expired)
      day = Time.now.utc.strftime('%F')
      @config.redis do |conn|
        conn.pipelined do |pipe|
          incr_stat_key(pipe, Keys::STAT_PROCESSED, processed, day)
          incr_stat_key(pipe, 'stat:failed', failed, day)
          incr_stat_key(pipe, Keys::STAT_EXPIRED, expired, day)
        end
      end
    end

    def incr_stat_key(pipe, key, value, day)
      return unless value.positive?

      pipe.call('INCRBY', key, value)
      pipe.call('INCRBY', "#{key}:#{day}", value)
      pipe.call('EXPIRE', "#{key}:#{day}", STATS_TTL)
    end

    # Pipelined identity write via Heartbeat, then dispatch any signals
    # the dashboard queued at `<identity>-signals`. Lazily builds the
    # Heartbeat the first time we beat so callers that bypass `run`
    # (embedded mode, tests) still work.
    def beat
      ensure_heartbeat
      sigs = @heartbeat.beat!
      sigs&.each { |sig| dispatch_signal(sig) }
    end

    def ensure_heartbeat
      return if @heartbeat

      @heartbeat = Heartbeat.new(
        identity: identity,
        config: @config,
        started_at: @started_at || Time.now.to_f,
        embedded: @embedded,
        quiet: -> { @done }
      )
    end

    # Erase the live-process footprint. flush_stats first so we don't drop
    # the final batch of counters; then Heartbeat#stop! removes us from the
    # `processes` SET and UNLINK-s the identity + work hashes.
    def clear_heartbeat
      flush_stats
      @heartbeat&.stop!
    end

    # Terminate the heartbeat loop and wait for it to exit before clear_heartbeat
    # removes us from the `processes` SET — otherwise a final in-flight beat could
    # SADD us back right after the SREM and the identity would linger for a full
    # 60s TTL.
    #
    # The join is unbounded on purpose. This used to be `wakeup` + `join(BEAT_PAUSE)`,
    # which lost the race whenever the beat was mid-Redis-call: `wakeup` does nothing
    # to a thread that isn't sleeping, so the loop then slept a full interval and the
    # bounded join returned with the thread still live — exactly the resurrect-after-
    # SREM this ordering exists to prevent. A condvar can't be missed (terminate flips
    # the flag inside the critical section the loop re-checks it in), so all that is
    # left to wait out is one in-flight beat, whose Redis calls are timeout-bounded.
    def stop_heartbeat
      @beat_timer.terminate
      thread = @heartbeat_thread
      return unless thread
      # Embedded dashboard-TERM can run `stop` from the beat itself; a self-join
      # raises ThreadError. The timer is terminated, so the loop exits after this beat.
      return if thread == Thread.current

      thread.join
    end

    # Heartbeat thread loop. `safe_thread` already wraps exceptions. Beats once up
    # front — TimerLoop#run waits before its first yield, and the dashboard has to
    # see this process the moment it can pick up jobs — then ticks until #stop
    # terminates the timer. Note it does NOT stop on `@done`: a *quieted* process
    # keeps beating so it publishes `quiet=true` instead of vanishing (#236).
    def start_heartbeat
      heartbeat
      @beat_timer.run { heartbeat }
      logger.info('Heartbeat stopping...')
    end

    # Dashboard-queued signals must behave exactly like OS signals, so a
    # standalone process re-delivers to itself and lets the installed trap run —
    # that wakes the main thread (CLI self-pipe / child dispatcher) so the
    # process actually exits instead of stopping its managers and then parking
    # forever. Embedded mode owns no traps (and self-TERM would kill the host
    # app), so quiet applies directly.
    def dispatch_signal(sig)
      case sig
      when 'TSTP' then @embedded ? quiet : redeliver(sig)
      when 'TERM' then request_shutdown
      else
        logger.warn { "Unknown signal in #{identity}-signals: #{sig.inspect}" }
      end
    end

    # The one way anything inside this process asks it to shut down gracefully:
    # dashboard-queued TERM, or a Manager that can no longer hold its
    # concurrency. Standalone hands off to the installed TERM trap; embedded
    # owns no traps, so it drains in place — on its own thread, because callers
    # may be a thread `stop` itself joins (the heartbeat) or kills (a Processor).
    def request_shutdown
      @embedded ? Thread.new { stop } : redeliver('TERM')
    end

    # Separate method so tests can stub it — really sending TERM/TSTP would
    # kill or suspend the test process.
    def redeliver(sig)
      ::Process.kill(sig, ::Process.pid)
    end

    # One Manager per capsule, each holding our shutdown request: a Manager
    # that can no longer replace a dead Processor has to take the process
    # down, and only the Launcher knows how this process exits.
    def build_managers
      @config.capsules.values.map { |cap| Manager.new(cap, shutdown: method(:request_shutdown)) }
    end

    # The periodic loops, built in one place because they are started together
    # (#run) and released together (#stop_periodic_components). Every process
    # runs every one of them; what differs is who does the work inside a tick:
    #
    #   poller / reaper   every process, work shared through Redis
    #   cron_poller       leader only enqueues — that is the exactly-once guard
    #   metrics_rollup    leader only writes the cluster-total chart buckets
    #                     (cadence: `config.metrics_rollup_interval`)
    #   queue_rollup      leader only writes the `qm|…` per-queue gauges
    #   metrics_flusher   NOT leader-gated: the counters it drains exist only in
    #                     this process's memory, so every process flushes its own
    #   history           Ent §5 snapshotter, leader-gated, opt-in via
    #                     `config.retain_history`
    def build_loops
      @poller = Wurk::Scheduled::Poller.new(@config)
      @cron_poller = Wurk::Cron::Poller.new(@config)
      @metrics_rollup = Wurk::Metrics::Rollup.new(@config)
      @queue_rollup = Wurk::Metrics::QueueRollup.new(@config)
      @metrics_flusher = Wurk::Metrics::Flusher.new(@config)
      @history = Wurk::History.new(@config) if @config.history_enabled?
    end

    # Filled in by #run. Declared up front so #initialize reads as the full
    # inventory of what a Launcher owns.
    def reset_thread_state
      @started_at = @heartbeat = @heartbeat_thread = @boot_reclaim_thread = nil
    end

    # Every worker process campaigns for the single cluster lock (`dear-leader`);
    # one wins and renews it, the rest follow and promote on its death. Cadence
    # falls back to the spec defaults (TTL 30 / renew 15 / follower 60) unless
    # the host tunes it, plus the short pre-campaign delay that keeps the first
    # CAS off the boot path. `Leader#start` no-ops under `WURK_LEADER=false`.
    def build_leader
      Wurk::Leader.new(
        config: @config,
        ttl: @config[:leader_ttl] || Wurk::Leader::DEFAULT_TTL,
        renew_interval: @config[:leader_renew_interval] || Wurk::Leader::DEFAULT_RENEW_INTERVAL,
        follower_interval: @config[:leader_follower_interval] || Wurk::Leader::DEFAULT_FOLLOWER_INTERVAL,
        initial_wait: @config[:leader_initial_wait] || Wurk::Leader::DEFAULT_INITIAL_WAIT
      )
    end

    # Deterministic boot-time orphan sweep: a SIGKILLed sibling's in-flight jobs
    # would otherwise wait a full reaper interval before recovery. One unguarded
    # scoped reclaim at start (no cluster lock — every booting worker helps) gets
    # them re-queued immediately. Best-effort: a Redis hiccup here must not abort
    # boot. Spec: docs/target/sidekiq-pro.md §3.2.
    def boot_reclaim
      @reaper.reclaim!
    rescue StandardError => e
      handle_exception(e, context: 'launcher-boot-reclaim') if respond_to?(:handle_exception)
    end

    # Reliable-fetch orphan reclamation. Every worker runs one; a cluster
    # `SET NX EX` lock ensures only one actually sweeps per interval, so this
    # is leader-independent (it keeps working if the leader dies). Tune the
    # cadence with `config.super_fetch_reaper_interval`.
    def build_reaper
      Wurk::Fetcher::Reaper.new(
        @config,
        interval: @config[:super_fetch_reaper_interval] || Wurk::Fetcher::Reaper::DEFAULT_INTERVAL
      )
    end

    # Returns a Health::Server when `config.health_check(...)` has set
    # `:health_check_options`; nil otherwise. Off by default — the listener
    # is opt-in to keep the worker's port surface minimal.
    def build_health_server
      opts = @config[:health_check_options]
      return nil unless opts

      Health::Server.new(
        self,
        port: opts.fetch(:port, Health::DEFAULT_PORT),
        bind: opts.fetch(:bind, Health::DEFAULT_BIND),
        ready_window: opts.fetch(:ready_window, Health::DEFAULT_READY_WINDOW)
      )
    end
  end
end
