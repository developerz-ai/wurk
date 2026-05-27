# frozen_string_literal: true

require_relative 'component'
require_relative 'keys'
require_relative 'processor'

module Wurk
  # Single-purpose owner of the Redis-side process heartbeat. Lifted out of
  # Wurk::Launcher so the launcher can stay focused on lifecycle and so the
  # heartbeat schema lives in one place readers can grep for.
  #
  # Each beat is one pipelined round-trip:
  #   SADD   processes <identity>
  #   HSET   <identity>          info concurrency busy beat quiet rss rtt_us
  #   EXPIRE <identity>          60
  #   UNLINK <identity>:work
  #   HSET   <identity>:work     <tid> <json> ...    (only if WORK_STATE non-empty)
  #   EXPIRE <identity>:work     60                  (only if WORK_STATE non-empty)
  #   LPOP   <identity>-signals  × BEAT_PAUSE
  #
  # The work hash is UNLINK-then-rewritten on every beat — a dropped beat
  # momentarily empties it, and ProcessSet#cleanup compensates by SREM-ing
  # identities whose `info` field has expired.
  #
  # Heartbeat owns only the wire. Signals queued by the dashboard are pulled
  # out of the pipelined results and returned to the caller for dispatch —
  # TSTP/TERM semantics live in Launcher.
  #
  # `:heartbeat` fires once on the first successful beat and again after any
  # network partition (rearmed when beat! rescues). `:beat` fires every tick.
  #
  # Spec: docs/target/sidekiq-free.md §12 (Launcher#❤️).
  class Heartbeat
    include Component

    # Cadence in seconds. Key TTL is 60s — a process is dead after ~6 misses.
    BEAT_PAUSE = 10
    TTL_SECONDS = 60

    attr_reader :identity, :rtt_us, :last_beat_at

    # `quiet:` is a callable so Launcher can keep ownership of its `@done`
    # flag without an awkward setter contract. `info_overrides:` lets the
    # caller (Launcher#embedded, tests) inject fields without forcing
    # Heartbeat to know about every flag the host process tracks.
    def initialize(identity:, config:, started_at: nil, embedded: false, quiet: nil)
      @identity = identity
      @config = config
      @started_at = started_at || Time.now.to_f
      @embedded = embedded
      @quiet_proc = quiet || -> { false }
      @first_heartbeat = true
      @rtt_us = 0
    end

    # Pipelined beat. Returns the drained signals as Array<String> on
    # success, or nil if Redis raised — the next successful beat refires
    # `:heartbeat` so partition recovery is observable.
    def beat!
      sigs, @rtt_us = pipelined_beat
      @last_beat_at = Time.now.to_f
      if @first_heartbeat
        @first_heartbeat = false
        fire_event(:heartbeat)
      end
      fire_event(:beat, oneshot: false)
      sigs.compact
    rescue StandardError => e
      @first_heartbeat = true
      handle_exception(e, { context: 'heartbeat' })
      nil
    end

    # Best-effort teardown. SREM removes us from the live list; UNLINK
    # drops the identity hash and its work mirror. Idempotent: if Redis
    # is down the next process boot's ProcessSet#cleanup prunes us.
    def stop!
      redis do |conn|
        conn.pipelined do |pipe|
          pipe.call('SREM', Keys::PROCESSES, @identity)
          pipe.call('UNLINK', @identity, "#{@identity}:work")
        end
      end
    rescue StandardError
      nil
    end

    private

    # Two extra writes (HSET + EXPIRE for the work mirror) when WORK_STATE
    # has entries, so `lead` shifts to skip them when slicing signals out
    # of the pipeline result.
    def pipelined_beat
      work_snapshot = Processor::WORK_STATE.dup
      lead = 4 + (work_snapshot.empty? ? 0 : 2)
      t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
      results = redis { |conn| conn.pipelined { |pipe| write_beat(pipe, work_snapshot) } }
      rtt = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond) - t0
      [results[lead, BEAT_PAUSE] || [], rtt]
    end

    def write_beat(pipe, work_snapshot)
      pipe.call('SADD', Keys::PROCESSES, @identity)
      pipe.call('HSET', @identity, *beat_hash_args(work_snapshot.size))
      pipe.call('EXPIRE', @identity, TTL_SECONDS)
      write_work_hash(pipe, work_snapshot)
      drain_signals(pipe)
    end

    def beat_hash_args(busy)
      [
        'info', Wurk.dump_json(info_hash),
        'concurrency', total_concurrency.to_s,
        'busy', busy.to_s,
        'beat', Time.now.to_f.to_s,
        'quiet', @quiet_proc.call.to_s,
        'rss', memory_usage_kb.to_s,
        'rtt_us', @rtt_us.to_s
      ]
    end

    def write_work_hash(pipe, work_snapshot)
      work_key = "#{@identity}:work"
      pipe.call('UNLINK', work_key)
      return if work_snapshot.empty?

      args = work_snapshot.flat_map { |tid, hash| [tid.to_s, Wurk.dump_json(hash)] }
      pipe.call('HSET', work_key, *args)
      pipe.call('EXPIRE', work_key, TTL_SECONDS)
    end

    # LPOP one entry per second of cadence so a flood of queued signals
    # can't stall the beat; anything older drains on the next beat.
    def drain_signals(pipe)
      BEAT_PAUSE.times { pipe.call('LPOP', "#{@identity}-signals") }
    end

    def info_hash
      caps = @config.capsules.each_value
      {
        'hostname' => hostname,
        'started_at' => @started_at,
        'pid' => ::Process.pid,
        'tag' => @config[:tag] || default_tag,
        'concurrency' => total_concurrency,
        'capsules' => capsules_info,
        'queues' => caps.flat_map(&:queues).uniq,
        'weights' => caps.map(&:weights),
        'labels' => Array(@config[:labels]),
        'identity' => @identity,
        'version' => Wurk::VERSION,
        'embedded' => @embedded
      }
    end

    def capsules_info
      @config.capsules.transform_values do |cap|
        { 'concurrency' => cap.concurrency, 'mode' => cap.mode.to_s, 'weights' => cap.weights }
      end
    end

    def total_concurrency
      @config.capsules.each_value.sum(&:concurrency)
    end

    # Linux first via /proc/self/statm[1] (resident pages × 4 KB);
    # `ps` fallback for macOS/BSD test runners. Zero on failure — the
    # dashboard shows "—" rather than crashing.
    def memory_usage_kb
      if ::File.exist?('/proc/self/statm')
        ::File.read('/proc/self/statm').split[1].to_i * 4
      else
        `ps -o rss= -p #{::Process.pid}`.to_i
      end
    rescue StandardError
      0
    end
  end
end
