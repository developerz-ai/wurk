# frozen_string_literal: true

require_relative 'component'
require_relative 'manager'
require_relative 'processor'
require_relative 'keys'

module Wurk
  # Top-level supervisor inside each worker process. Owns the Manager pool
  # (one per Capsule), the scheduler poller, and the heartbeat thread.
  #
  # Lifecycle:
  #   * `run(async_beat:)` — freeze config, start heartbeat, poller, managers.
  #   * `quiet`            — stop fetching across all managers + poller.
  #   * `stop`             — graceful drain inside `config[:timeout]`.
  #   * `heartbeat`        — one-shot beat (also driven by the heartbeat thread).
  #
  # `flush_stats` rolls per-process Processor counters (PROCESSED / FAILURE)
  # into the global + per-day Redis strings every beat. Per-day keys carry
  # `STATS_TTL` so old days expire automatically.
  #
  # Heartbeat writes the `<identity>` HASH (info/concurrency/busy/beat/quiet/
  # rss/rtt_us, EXPIRE 60s), adds identity to the `processes` SET, mirrors
  # the in-process `WORK_STATE` into the `<identity>:work` HASH, and drains
  # any signals queued at `<identity>-signals`. First successful beat (and
  # any beat after a network partition) fires `:heartbeat`; every beat
  # fires `:beat`.
  #
  # Spec: docs/target/sidekiq-free.md §12 (Sidekiq::Launcher).
  class Launcher
    include Component

    # 5 years, in seconds. Per-day `stat:processed:YYYY-MM-DD` /
    # `stat:failed:YYYY-MM-DD` strings carry this TTL so they roll off
    # without manual cleanup.
    STATS_TTL = 5 * 365 * 24 * 60 * 60

    # Heartbeat cadence in seconds. Key TTL on `<identity>` is 60s — a
    # process is treated as dead after ~6 missed beats.
    BEAT_PAUSE = 10

    attr_accessor :managers, :poller

    def initialize(config, embedded: false)
      @config = config
      @embedded = embedded
      @done = false
      @managers = config.capsules.values.map { |cap| Manager.new(cap) }
      @poller = build_poller
      @first_heartbeat = true
      @started_at = nil
      @heartbeat_thread = nil
    end

    # Boot order matters:
    #   1. freeze! the config so mutations after fork are visible mistakes.
    #   2. spawn the heartbeat thread BEFORE the managers so the dashboard
    #      sees the process the moment it can pick up jobs.
    #   3. start the poller (scheduler).
    #   4. start the managers (which start their processors).
    def run(async_beat: true)
      @started_at = Time.now.to_f
      @config.freeze!
      @heartbeat_thread = safe_thread('heartbeat', &method(:start_heartbeat)) if async_beat
      @poller&.start
      @managers.each(&:start)
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
    # round trip covers all six writes. Skips when both counters are zero
    # to avoid touching keys we have nothing to add to.
    def flush_stats
      processed = Processor::PROCESSED.reset
      failed = Processor::FAILURE.reset
      return if processed.zero? && failed.zero?

      write_stats(processed, failed)
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

    def write_stats(processed, failed)
      day = Time.now.utc.strftime('%F')
      @config.redis do |conn|
        conn.pipelined do |pipe|
          pipe.call('INCRBY', Keys::STAT_PROCESSED, processed)
          pipe.call('INCRBY', "#{Keys::STAT_PROCESSED}:#{day}", processed)
          pipe.call('EXPIRE', "#{Keys::STAT_PROCESSED}:#{day}", STATS_TTL)
          pipe.call('INCRBY', 'stat:failed', failed)
          pipe.call('INCRBY', "stat:failed:#{day}", failed)
          pipe.call('EXPIRE', "stat:failed:#{day}", STATS_TTL)
        end
      end
    end

    # The actual `<identity>` write. Side-effects:
    #   * SADD `processes` (membership for dashboards).
    #   * HSET `<identity>` info/concurrency/busy/beat/quiet/rss/rtt_us.
    #   * EXPIRE `<identity>` 60s.
    #   * UNLINK + repopulate `<identity>:work` from WORK_STATE (so a lost
    #     beat momentarily empties the work hash; ProcessSet#cleanup
    #     compensates).
    #   * Drain `<identity>-signals` (LPOP × BEAT_PAUSE) and dispatch any
    #     TSTP/TERM the dashboard queued.
    def beat
      sigs = nil
      rtt_us = 0
      begin
        sigs, rtt_us = beat_pipeline
        if @first_heartbeat
          @first_heartbeat = false
          fire_event(:heartbeat)
        end
        fire_event(:beat, oneshot: false)
      rescue StandardError => e
        # Partition: arm :heartbeat for the next successful beat so a
        # recovery is observable.
        @first_heartbeat = true
        handle_exception(e, { context: 'heartbeat' })
        return
      end

      sigs&.compact&.each { |sig| dispatch_signal(sig) }
      rtt_us
    end

    # Runs the pipelined beat + signal drain. Splits into its own method so
    # the rtt_us measurement scopes only the network call. Returns the
    # signals tail and the elapsed microseconds.
    def beat_pipeline
      work_snapshot = Processor::WORK_STATE.dup
      lead = 4 + (work_snapshot.empty? ? 0 : 2) # SADD,HSET,EXPIRE,UNLINK[,HSET,EXPIRE]

      t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
      results = @config.redis { |conn| conn.pipelined { |pipe| write_beat(pipe, work_snapshot) } }
      rtt_us = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond) - t0
      [results[lead, BEAT_PAUSE] || [], rtt_us]
    end

    # All pipelined writes that compose one beat. Order matters: the
    # extract_signals math depends on the leading-writes count.
    def write_beat(pipe, work_snapshot)
      pipe.call('SADD', Keys::PROCESSES, identity)
      pipe.call('HSET', identity, *beat_hash_args(work_snapshot.size))
      pipe.call('EXPIRE', identity, 60)
      write_work_hash(pipe, work_snapshot)
      drain_signals(pipe)
    end

    def beat_hash_args(busy)
      [
        'info', build_info_json,
        'concurrency', total_concurrency.to_s,
        'busy', busy.to_s,
        'beat', Time.now.to_f.to_s,
        'quiet', @done.to_s,
        'rss', memory_usage_kb.to_s,
        'rtt_us', '0'
      ]
    end

    # UNLINK the work hash and (if any in-flight) repopulate. UNLINK is
    # non-blocking; HSET with the whole field set is atomic enough for
    # readers since pipelining preserves order on a single connection.
    def write_work_hash(pipe, work_snapshot)
      work_key = "#{identity}:work"
      pipe.call('UNLINK', work_key)
      return if work_snapshot.empty?

      args = work_snapshot.flat_map { |tid, hash| [tid.to_s, Wurk.dump_json(hash)] }
      pipe.call('HSET', work_key, *args)
      pipe.call('EXPIRE', work_key, 60)
    end

    # LPOP up to BEAT_PAUSE entries (one per second of cadence) so a flood
    # of queued signals can't stall the beat. Anything older drains on the
    # next beat.
    def drain_signals(pipe)
      BEAT_PAUSE.times { pipe.call('LPOP', "#{identity}-signals") }
    end

    # Erase the live-process footprint. Best-effort: if Redis is down on
    # shutdown the next process boot's cleanup will prune us anyway.
    def clear_heartbeat
      flush_stats
      @config.redis do |conn|
        conn.pipelined do |pipe|
          pipe.call('SREM', Keys::PROCESSES, identity)
          pipe.call('UNLINK', identity, "#{identity}:work")
        end
      end
    rescue StandardError
      nil
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

    def total_concurrency
      @config.capsules.each_value.sum(&:concurrency)
    end

    # Linux: /proc/self/statm[1] is resident pages; multiply by 4 for KB.
    # Other platforms fall through to `ps`. Zero on failure — non-fatal,
    # the dashboard just shows "—".
    def memory_usage_kb
      if ::File.exist?('/proc/self/statm')
        ::File.read('/proc/self/statm').split[1].to_i * 4
      else
        `ps -o rss= -p #{::Process.pid}`.to_i
      end
    rescue StandardError
      0
    end

    # JSON payload stored at `<identity>` HASH info field. Read by
    # ProcessSet#each + the dashboard's process list.
    def build_info_json
      Wurk.dump_json(info_hash)
    end

    def info_hash
      caps = @config.capsules.each_value
      {
        'hostname' => hostname,
        'started_at' => @started_at || Time.now.to_f,
        'pid' => ::Process.pid,
        'tag' => @config[:tag] || default_tag,
        'concurrency' => total_concurrency,
        'capsules' => capsules_info,
        'queues' => caps.flat_map(&:queues).uniq,
        'weights' => caps.map(&:weights),
        'labels' => Array(@config[:labels]),
        'identity' => identity,
        'version' => Wurk::VERSION,
        'embedded' => @embedded
      }
    end

    def capsules_info
      @config.capsules.transform_values do |cap|
        {
          'concurrency' => cap.concurrency,
          'mode' => cap.mode.to_s,
          'weights' => cap.weights
        }
      end
    end

    # PR 6 lands `Wurk::Scheduled::Poller`. Until then this returns nil
    # and the launcher tolerates a missing poller — managers still run.
    def build_poller
      return nil unless defined?(Wurk::Scheduled::Poller)

      Wurk::Scheduled::Poller.new(@config)
    end
  end
end
