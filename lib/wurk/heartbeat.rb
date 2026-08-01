# frozen_string_literal: true

require 'etc'

require_relative 'component'
require_relative 'keys'
require_relative 'processor'

module Wurk
  # Single-purpose owner of the Redis-side process heartbeat. Lifted out of
  # Wurk::Launcher so the launcher can stay focused on lifecycle and so the
  # heartbeat schema lives in one place readers can grep for.
  #
  # Each beat is two pipelined round-trips. The identity write:
  #   SADD   processes <identity>
  #   HSET   <identity>          info concurrency busy beat quiet rss rtt_us
  #   EXPIRE <identity>          60
  #   UNLINK <identity>:work
  #   HSET   <identity>:work     <tid> <json> ...    (only if WORK_STATE non-empty)
  #   EXPIRE <identity>:work     60                  (only if WORK_STATE non-empty)
  # then the signal drain:
  #   LPOP   <identity>-signals  × BEAT_PAUSE
  # Two rather than one because only the first is safe to replay — see
  # #pipelined_beat and #drain_signals.
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
      emit_statsd_gauges
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

    # Every command in #write_beat converges on the state this snapshot
    # describes however many times it lands, so the beat claims apply-safety and
    # rides out a blip the way it did before the pool started splitting replay
    # by it. `rtt_us` measures this write alone — the signal drain that follows
    # is a separate checkout and deliberately not part of the gauge.
    def pipelined_beat
      work_snapshot = Processor::WORK_STATE.dup
      t0 = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond)
      redis(idempotent: true) { |conn| conn.pipelined { |pipe| write_beat(pipe, work_snapshot) } }
      rtt = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :microsecond) - t0
      [drain_signals, rtt]
    end

    def write_beat(pipe, work_snapshot)
      pipe.call('SADD', Keys::PROCESSES, @identity)
      pipe.call('HSET', @identity, *beat_hash_args(work_snapshot.size))
      pipe.call('EXPIRE', @identity, TTL_SECONDS)
      write_work_hash(pipe, work_snapshot)
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

    # Its own checkout, and never an idempotent one: LPOP is destructive and
    # carries its result in the reply, so a replay after a lost reply discards
    # whatever the first attempt already popped — and a discarded entry is a
    # dashboard TERM or TSTP this process never acts on. Fused into the beat
    # pipeline it would have dragged those writes down to the same no-replay
    # default, or worse, invited a later sweep to claim the LPOPs alongside
    # them. Runs after the beat so a signal only leaves Redis once the write
    # that reports us alive has landed.
    #
    # LPOP one entry per second of cadence so a flood of queued signals
    # can't stall the beat; anything older drains on the next beat.
    def drain_signals
      redis { |conn| conn.pipelined { |pipe| BEAT_PAUSE.times { pipe.call('LPOP', "#{@identity}-signals") } } }
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
      }.merge(host_facts)
    end

    # Static hardware facts for the Busy page's per-host grouping. Additive
    # `info` fields only — Sidekiq Web ignores keys it doesn't know, so the
    # drop-in wire contract holds. Best-effort: nil/0 when the platform has
    # no readable source (the dashboard renders a dash).
    def host_facts
      @host_facts ||= {
        'cpu_model' => cpu_model,
        'cores' => cores,
        'memory_total_kb' => memory_total_kb
      }
    end

    def cores(etc = Etc)
      etc.nprocessors
    # NotImplementedError is a ScriptError, outside StandardError — and it's
    # exactly what Etc raises on platforms without sysconf.
    rescue StandardError, NotImplementedError
      nil
    end

    def cpu_model
      if ::File.exist?('/proc/cpuinfo')
        line = ::File.foreach('/proc/cpuinfo').find { |l| l.start_with?('model name') }
        line&.split(':', 2)&.last&.strip
      else
        model = `sysctl -n machdep.cpu.brand_string 2>/dev/null`.strip
        model.empty? ? nil : model
      end
    rescue StandardError
      nil
    end

    def memory_total_kb
      if ::File.exist?('/proc/meminfo')
        line = ::File.foreach('/proc/meminfo').find { |l| l.start_with?('MemTotal') }
        line.to_s[/\d+/].to_i
      else
        `sysctl -n hw.memsize 2>/dev/null`.to_i / 1024
      end
    rescue StandardError
      0
    end

    def capsules_info
      @config.capsules.transform_values do |cap|
        { 'concurrency' => cap.concurrency, 'mode' => cap.mode.to_s, 'weights' => cap.weights }
      end
    end

    def total_concurrency
      @config.capsules.each_value.sum(&:concurrency)
    end

    # Best-effort statsd snapshot per beat. Emits `sidekiq.busy` (this
    # process's in-flight job count) and `sidekiq.queue.size` (per queue
    # LLEN). Tagged with `process:<identity>` so multi-process emissions
    # of the global `queue.size` are tag-distinguishable downstream — pick
    # `max` across the process tag in your dashboard. No-op when
    # `config.dogstatsd` is unset (Statsd.gauge short-circuits on nil
    # client) so the LLEN pipeline is also skipped.
    # Spec hint: docs/target/sidekiq-ent.md §5.2 names (`busy`, `queue.size`).
    def emit_statsd_gauges
      return unless Wurk::Metrics::Statsd.client

      busy = Processor::WORK_STATE.size
      Wurk::Metrics::Statsd.gauge('busy', busy, tags: ["process:#{@identity}"])
      emit_queue_sizes
    rescue StandardError => e
      handle_exception(e, { context: 'heartbeat metrics' })
    end

    def emit_queue_sizes
      queues = @config.capsules.each_value.flat_map(&:queues).uniq
      return if queues.empty?

      sizes = redis { |conn| conn.pipelined { |pipe| queues.each { |q| pipe.call('LLEN', "queue:#{q}") } } }
      queues.zip(sizes).each do |queue, size|
        Wurk::Metrics::Statsd.gauge(
          'queue.size', size,
          tags: ["queue:#{queue}", "process:#{@identity}"]
        )
      end
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
