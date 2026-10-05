# frozen_string_literal: true

require 'json'
require_relative '../component'
require_relative '../keys'
require_relative '../version'

module Wurk
  module Metrics
    # Prometheus text exposition (format 0.0.4) served by the health listener at
    # `GET /metrics`. Reads only keys Sidekiq already writes — no new Redis keys.
    #
    # Two families, and the difference matters when aggregating:
    #   * cluster gauges/counters (`wurk_queue_*`, `wurk_processed_total`, …)
    #     come straight from shared Redis, so every scrape target reports the
    #     same value. Aggregate with `max`, never `sum`.
    #   * `wurk_process_*` / `wurk_swarm_*` describe THIS host's process group:
    #     heartbeat identities sharing this process's nonce (the swarm parent
    #     stamps one nonce that every child inherits), so a scrape of one pod
    #     covers all of its children no matter which child owns the port.
    #
    # One Redis checkout per refresh — two pipelines, because the second needs
    # the queue and process names the first returns — and the snapshot is cached
    # for `ttl` seconds, so a scrape storm costs at most one refresh per window.
    # A failed refresh is cached for the same window: a dead Redis is not
    # hammered once per scrape.
    class Prometheus
      CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8'
      TTL = 1.0
      LABEL_ESCAPES = { '\\' => '\\\\', '"' => '\\"', "\n" => '\\n' }.freeze
      LABEL_ESCAPES_RE = /[\\"\n]/
      PROCESS_FIELDS = %w[busy concurrency beat rss quiet].freeze
      SCALARS = {
        processed: ['GET', Keys::STAT_PROCESSED],
        failed: ['GET', 'stat:failed'],
        scheduled: ['ZCARD', Keys::SCHEDULE],
        retries: ['ZCARD', Keys::RETRY],
        dead: ['ZCARD', Keys::DEAD]
      }.freeze
      # Names come last: the detail pass is built from them.
      FIRST_PASS = [*SCALARS.values, ['SMEMBERS', Keys::QUEUES_SET], ['SMEMBERS', Keys::PROCESSES]].freeze

      QUEUE_GAUGES = [
        ['wurk_queue_size', 'Jobs enqueued per queue.', :depth.to_proc],
        ['wurk_queue_latency_seconds', 'Age of the oldest job per queue.', :latency.to_proc]
      ].freeze
      CLUSTER_GAUGES = [
        ['wurk_scheduled_size', 'Jobs in the schedule set.', :scheduled.to_proc],
        ['wurk_retry_size', 'Jobs in the retry set.', :retries.to_proc],
        ['wurk_dead_size', 'Jobs in the dead set.', :dead.to_proc],
        ['wurk_processes', 'Live worker processes, cluster-wide.', ->(snap) { snap.processes.size }],
        ['wurk_busy', 'Jobs executing right now, cluster-wide.', ->(snap) { snap.processes.sum(&:busy) }],
        ['wurk_concurrency', 'Worker threads, cluster-wide.', ->(snap) { snap.processes.sum(&:concurrency) }]
      ].freeze
      PROCESS_GAUGES = [
        ['wurk_process_busy', 'Jobs executing in this local process.', ->(row, _now) { row.busy }],
        ['wurk_process_concurrency', 'Worker threads in this local process.', ->(row, _now) { row.concurrency }],
        ['wurk_process_rss_bytes', 'Resident set size reported by the heartbeat.', ->(row, _now) { row.rss_kb * 1024 }],
        ['wurk_process_heartbeat_age_seconds', 'Seconds since the last heartbeat.',
         ->(row, now) { row.beat ? [now - row.beat, 0.0].max : 0.0 }],
        ['wurk_process_quiet', '1 when the process is quiet (TSTP).', ->(row, _now) { row.quiet ? 1 : 0 }]
      ].freeze

      QueueRow = Struct.new(:name, :depth, :latency)
      ProcessRow = Struct.new(:identity, :pid, :busy, :concurrency, :beat, :rss_kb, :quiet)
      Snapshot = Struct.new(:ok, :taken_at, :processed, :failed, :scheduled, :retries, :dead, :queues, :processes,
                            keyword_init: true)

      def initialize(config, ttl: TTL, nonce: Component::PROCESS_NONCE, hostname: Component.hostname,
                     clock: -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) })
        @config = config
        @ttl = ttl
        @local_suffix = ":#{nonce}"
        @local_prefix = "#{hostname}:"
        @clock = clock
        @lock = ::Mutex.new
        @snapshot = nil
      end

      # Cached Snapshot; `ok` false when Redis could not be read.
      def snapshot
        @lock.synchronize do
          now = @clock.call
          @snapshot = fetch(now) if @snapshot.nil? || now - @snapshot.taken_at >= @ttl
          @snapshot
        end
      end

      # This host's process group (see class doc), from a Snapshot.
      def local_processes(snap)
        snap.processes.select { |row| local?(row.identity) }
      end

      # Local processes whose heartbeat landed within `window` seconds.
      def fresh_local(snap, window, now = ::Time.now.to_f)
        local_processes(snap).select { |row| row.beat && now - row.beat < window }
      end

      def render(expected_children: nil, fresh_window: 30)
        snap = snapshot
        out = +''
        build_info(out)
        gauge(out, 'wurk_redis_up', 'Whether the last metrics refresh could read Redis.', [[nil, snap.ok ? 1 : 0]])
        if snap.ok
          cluster(out, snap)
          local(out, snap, expected_children, fresh_window)
        end
        out
      end

      private

      def local?(identity)
        identity.end_with?(@local_suffix) && identity.start_with?(@local_prefix)
      end

      def fetch(now)
        first, detail = read_redis
        queues, processes = names(first)
        Snapshot.new(ok: true, taken_at: now, **scalars(first),
                     queues: queue_rows(queues, detail),
                     processes: process_rows(processes, detail.drop(queues.size * 2)))
      rescue StandardError => e
        @config.logger&.warn { "Wurk::Metrics::Prometheus refresh failed: #{e.class}: #{e.message}" }
        Snapshot.new(ok: false, taken_at: now, queues: [], processes: [])
      end

      def read_redis
        @config.redis(idempotent: true) do |conn|
          first = conn.pipelined { |pipe| FIRST_PASS.each { |cmd| pipe.call(*cmd) } }
          [first, Array(conn.pipelined { |pipe| queue_detail(pipe, *names(first)) })]
        end
      end

      def scalars(first)
        SCALARS.keys.zip(first.first(SCALARS.size).map(&:to_i)).to_h
      end

      def names(first)
        first.last(2).map { |list| Array(list).sort }
      end

      def queue_detail(pipe, queues, processes)
        queues.each do |q|
          pipe.call('LLEN', Keys.queue(q))
          pipe.call('LINDEX', Keys.queue(q), -1)
        end
        processes.each { |id| pipe.call('HMGET', id, *PROCESS_FIELDS) }
      end

      def queue_rows(queues, detail)
        queues.each_with_index.map do |name, i|
          QueueRow.new(name, detail[i * 2].to_i, latency(detail[(i * 2) + 1]))
        end
      end

      # An expired identity (dead process not yet pruned from `processes`)
      # answers HMGET with all nils; it is not a process, so it is dropped.
      def process_rows(processes, fields)
        processes.zip(fields).filter_map do |identity, (busy, concurrency, beat, rss, quiet)|
          next if beat.nil? && busy.nil?

          ProcessRow.new(identity, identity.split(':')[-2].to_i, busy.to_i, concurrency.to_i,
                         beat&.to_f, rss.to_i, quiet == 'true')
        end
      end

      def latency(payload)
        return 0.0 if payload.nil?

        job = ::JSON.parse(payload)
        Wurk::JobRecord.latency_from(job['enqueued_at'] || job['created_at'])
      rescue ::JSON::ParserError, ::TypeError, ::NoMethodError
        0.0
      end

      def build_info(out)
        labels = { 'version' => Wurk::VERSION, 'ruby_version' => RUBY_VERSION }
        gauge(out, 'wurk_build_info', 'Wurk build information.', [[labels, 1]])
      end

      def cluster(out, snap)
        counter(out, 'wurk_processed_total', 'Jobs processed, cluster-wide (stat:processed).', snap.processed)
        counter(out, 'wurk_failed_total', 'Jobs failed, cluster-wide (stat:failed).', snap.failed)
        QUEUE_GAUGES.each do |name, help, value|
          gauge(out, name, help, snap.queues.map { |q| [{ 'queue' => q.name }, value.call(q)] })
        end
        CLUSTER_GAUGES.each { |name, help, value| gauge(out, name, help, [[nil, value.call(snap)]]) }
      end

      def local(out, snap, expected, window)
        now = ::Time.now.to_f
        if expected
          gauge(out, 'wurk_swarm_children_expected', 'Children this swarm is configured to run.', [[nil, expected]])
        end
        gauge(out, 'wurk_swarm_children_fresh', 'Local processes with a heartbeat inside the ready window.',
              [[nil, fresh_local(snap, window, now).size]])
        rows = local_processes(snap)
        PROCESS_GAUGES.each do |name, help, value|
          gauge(out, name, help, rows.map { |row| [{ 'pid' => row.pid.to_s }, value.call(row, now)] })
        end
      end

      def counter(out, name, help, value)
        family(out, name, help, 'counter', [[nil, value]])
      end

      def gauge(out, name, help, samples)
        family(out, name, help, 'gauge', samples)
      end

      def family(out, name, help, type, samples)
        out << "# HELP #{name} #{help}\n# TYPE #{name} #{type}\n"
        samples.each { |labels, value| out << name << label_set(labels) << ' ' << number(value) << "\n" }
      end

      def label_set(labels)
        return '' if labels.nil? || labels.empty?

        "{#{labels.map { |k, v| "#{k}=\"#{escape(v)}\"" }.join(',')}}"
      end

      def escape(value)
        value.to_s.gsub(LABEL_ESCAPES_RE, LABEL_ESCAPES)
      end

      def number(value)
        value.is_a?(Float) ? value.round(3).to_s : value.to_i.to_s
      end
    end
  end
end
