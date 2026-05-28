# frozen_string_literal: true

require_relative 'component'
require_relative 'manager'
require_relative 'processor'
require_relative 'heartbeat'
require_relative 'health'
require_relative 'keys'
require_relative 'scheduled'

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

    attr_accessor :managers, :poller

    def initialize(config, embedded: false)
      @config = config
      @embedded = embedded
      @done = false
      @managers = config.capsules.values.map { |cap| Manager.new(cap) }
      @poller = build_poller
      @started_at = nil
      @heartbeat = nil
      @heartbeat_thread = nil
      @health_server = build_health_server
    end

    # Boot order matters:
    #   1. freeze! the config so mutations after fork are visible mistakes.
    #   2. spawn the heartbeat thread BEFORE the managers so the dashboard
    #      sees the process the moment it can pick up jobs.
    #   3. start the poller (scheduler).
    #   4. start the managers (which start their processors).
    #   5. start the health probe server LAST so the listener doesn't
    #      accept k8s probes until the rest of the launcher is up.
    def run(async_beat: true)
      @started_at = Time.now.to_f
      @config.freeze!
      @heartbeat_thread = safe_thread('heartbeat', &method(:start_heartbeat)) if async_beat
      @poller&.start
      @managers.each(&:start)
      @health_server&.start
    end

    # Idempotent. Flips `stopping?` true, halts fetching across every
    # Manager + the poller, then fires the `:quiet` event in reverse
    # registration order so teardown hooks run LIFO.
    def quiet
      return if @done

      @done = true
      @managers.each(&:quiet)
      @poller&.terminate
      fire_event(:quiet, reverse: true)
    end

    # Graceful shutdown. Deadline is monotonic so wall-clock skew can't
    # extend it. Managers stop in parallel threads so a slow capsule
    # doesn't block its siblings.
    def stop
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + (@config[:timeout] || 25)
      quiet
      stoppers = @managers.map { |m| Thread.new { m.stop(deadline) } }
      fire_event(:shutdown, reverse: true)
      stoppers.each(&:join)
      clear_heartbeat
      fire_event(:exit, reverse: true)
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
      # Replay-safety: counters were reset above, so a Redis blip would
      # otherwise drop stats. We log and accept — the per-job at-least-once
      # semantics don't apply to *counters*, and the next beat resets again.
      handle_exception(e, { context: 'flush_stats' })
    end

    # Used by tests to inspect the heartbeat thread; not part of the
    # Sidekiq public surface.
    attr_reader :heartbeat_thread

    private

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
    # `processes` SET and UNLINK-s the identity + work hashes. The probe
    # server is closed alongside so kubelet stops getting 200s after the
    # process is no longer healthy.
    def clear_heartbeat
      flush_stats
      @heartbeat&.stop!
      @health_server&.stop
    end

    # Heartbeat thread loop. `safe_thread` already wraps exceptions; we
    # exit the loop the moment `stop` flips @done so the thread doesn't
    # outlive the shutdown.
    def start_heartbeat
      until @done
        heartbeat
        sleep BEAT_PAUSE
      end
      logger.info('Heartbeat stopping...')
    end

    def dispatch_signal(sig)
      case sig
      when 'TSTP' then quiet
      when 'TERM' then stop
      else
        logger.warn { "Unknown signal in #{identity}-signals: #{sig.inspect}" }
      end
    end

    def build_poller
      Wurk::Scheduled::Poller.new(@config)
    end

    # Returns a Health::Server when `config.health_check(...)` has set
    # `:health_check_options`; nil otherwise. Off by default — the listener
    # is opt-in to keep the worker's port surface minimal.
    def build_health_server
      opts = @config[:health_check_options]
      return nil unless opts

      Health::Server.new(
        self,
        port:         opts.fetch(:port, Health::DEFAULT_PORT),
        bind:         opts.fetch(:bind, Health::DEFAULT_BIND),
        ready_window: opts.fetch(:ready_window, Health::DEFAULT_READY_WINDOW)
      )
    end
  end
end
