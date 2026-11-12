# frozen_string_literal: true

require 'json'
require_relative '../component'
require_relative '../keys'
require_relative '../version'
require_relative '../queue_consumers'
require_relative 'process_counters'

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
    #     `wurk_leader` is the same: 1 on every scrape target in the group that
    #     holds the lease.
    #   * `wurk_fetch_errors_total`, `wurk_reaper_reclaimed_total` and the other
    #     ProcessCounters families, the Redis pool gauges and
    #     `wurk_job_duration_seconds` count in the memory of the process that
    #     owns the port, so under a swarm they are a sample of one child. `rate`
    #     them; a child restart resets them.
    #   * `wurk_swarm_child_restarts_total` / `wurk_swarm_crash_streak` are the
    #     swarm parent's, read through Swarm::RestartCounters, so they survive
    #     child restarts; present only inside a swarm child.
    #
    # One Redis checkout per refresh — two pipelines, because the second needs
    # the queue and process names the first returns — and the snapshot is cached
    # for `ttl` seconds, so a scrape storm costs at most one refresh per window.
    # A failed refresh is cached for the same window: a dead Redis is not
    # hammered once per scrape.
    class Prometheus
      include Exposition

      CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8'
      TTL = 1.0
      PROCESS_FIELDS = %w[busy concurrency beat rss quiet info rtt_us].freeze
      # The last field of a heartbeat work entry (`{"queue":…,"payload":…,"run_at":…}`);
      # anchored at the end so a `run_at` inside the escaped payload never matches.
      RUN_AT_RE = /"run_at":(\d+(?:\.\d+)?)\}\z/
      PSS_FIELDS = %w[Pss].freeze
      SCALARS = {
        processed: ['GET', Keys::STAT_PROCESSED],
        failed: ['GET', 'stat:failed'],
        scheduled: ['ZCARD', Keys::SCHEDULE],
        retries: ['ZCARD', Keys::RETRY],
        dead: ['ZCARD', Keys::DEAD]
      }.freeze
      # Score of each set's earliest member: past due by now - score when the
      # scheduler is behind.
      SET_HEADS = Scheduled::SETS.map { |set| ['ZRANGE', set, 0, 0, 'WITHSCORES'] }.freeze
      # Names come last: the detail pass is built from them.
      FIRST_PASS = [*SCALARS.values, *SET_HEADS, ['GET', Wurk::Leader::DEFAULT_KEY],
                    ['SMEMBERS', Keys::QUEUES_SET], ['SMEMBERS', Keys::PROCESSES]].freeze

      QUEUE_GAUGES = [
        ['wurk_queue_size', 'Jobs enqueued per queue.', :depth.to_proc],
        ['wurk_queue_latency_seconds', 'Age of the oldest job per queue.', :latency.to_proc],
        ['wurk_queue_consumers', 'Live processes subscribed to the queue, quiet ones included.', :consumers.to_proc]
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
        ['wurk_process_quiet', '1 when the process is quiet (TSTP).', ->(row, _now) { row.quiet ? 1 : 0 }],
        ['wurk_process_redis_rtt_seconds', 'Round trip of the last heartbeat write.',
         ->(row, _now) { row.rtt_us / 1_000_000.0 }],
        ['wurk_process_oldest_job_seconds', 'Age of the longest-running job in the process; 0 when idle.',
         ->(row, now) { row.oldest_run_at ? [now - row.oldest_run_at, 0.0].max : 0.0 }],
        ['wurk_process_pss_bytes', 'Proportional set size from /proc/<pid>/smaps_rollup (Linux only).',
         ->(row, _now) { pss_bytes(row.pid) }]
      ].freeze
      def self.pss_bytes(pid)
        kb = Heartbeat.smaps_kb(pid, PSS_FIELDS)
        kb && (kb * 1024)
      rescue ::SystemCallError, ::IOError
        nil
      end

      QueueRow = Struct.new(:name, :depth, :latency, :consumers)
      ProcessRow = Struct.new(:identity, :pid, :busy, :concurrency, :beat, :rss_kb, :quiet, :queues, :rtt_us,
                              :oldest_run_at)
      Snapshot = Struct.new(:ok, :taken_at, :processed, :failed, :scheduled, :retries, :dead, :queues, :processes,
                            :leader, :set_heads, keyword_init: true)

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

      # `swarm:` is a Swarm::RestartCounters::Snapshot, nil outside a swarm child.
      def render(expected_children: nil, fresh_window: 30, swarm: nil)
        snap = snapshot
        out = +''
        build_info(out)
        gauge(out, 'wurk_redis_up', 'Whether the last metrics refresh could read Redis.', [[nil, snap.ok ? 1 : 0]])
        ProcessFamilies.render(out, swarm: swarm)
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

      def fetch(now) # rubocop:disable Metrics/AbcSize
        first, detail = read_redis
        queues, processes = names(first)
        rows = process_rows(processes, detail.drop(queues.size * 2), local_identities(processes))
        Snapshot.new(ok: true, taken_at: now, **scalars(first), leader: first[SCALARS.size + SET_HEADS.size],
                     set_heads: heads_of_sets(first),
                     queues: queue_rows(queues, detail, rows), processes: rows)
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

      # Work hashes are read for this host's group only: the oldest-job gauge is
      # per local pid, and a fleet-wide read would grow with every busy thread.
      def local_identities(processes)
        processes.select { |id| local?(id) }
      end

      # `{ set => score of its earliest member }`, nil for an empty set.
      def heads_of_sets(first)
        Scheduled::SETS.zip(first[SCALARS.size, SET_HEADS.size]).to_h { |set, head| [set, head_score(head)] }
      end

      # ZRANGE WITHSCORES answers [member, score] (RESP3: [[member, score]]).
      def head_score(head)
        score = Array(head).flatten[1]
        score&.to_f
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
        local_identities(processes).each { |id| pipe.call('HVALS', "#{id}:work") }
      end

      def queue_rows(queues, detail, processes)
        consumers = processes.flat_map(&:queues).tally
        queues.each_with_index.map do |name, i|
          QueueRow.new(name, detail[i * 2].to_i, latency(detail[(i * 2) + 1]), consumers.fetch(name, 0))
        end
      end

      # An expired identity (dead process not yet pruned from `processes`)
      # answers HMGET with all nils; it is not a process, so it is dropped.
      def process_rows(processes, detail, locals)
        oldest = locals.zip(detail.drop(processes.size)).to_h { |id, work| [id, oldest_run_at(work)] }
        processes.zip(detail).filter_map do |identity, fields|
          process_row(identity, fields, oldest[identity]) unless fields[2].nil? && fields[0].nil?
        end
      end

      def process_row(identity, (busy, concurrency, beat, rss, quiet, info, rtt_us), oldest)
        ProcessRow.new(identity, identity.split(':')[-2].to_i, busy.to_i, concurrency.to_i, beat&.to_f, rss.to_i,
                       quiet == 'true', QueueConsumers.subscribed(info), rtt_us.to_i, oldest)
      end

      def oldest_run_at(work)
        Array(work).filter_map { |entry| entry[RUN_AT_RE, 1]&.to_f }.min
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
        scheduler_lag(out, snap)
      end

      def scheduler_lag(out, snap)
        now = ::Time.now.to_f
        gauge(out, 'wurk_scheduler_lag_seconds', 'How far past due the earliest retry / scheduled job is; 0 when none.',
              snap.set_heads.map { |set, score| [{ 'set' => set }, score ? [now - score, 0.0].max : 0.0] })
      end

      def local(out, snap, expected, window)
        now = ::Time.now.to_f
        leader_gauge(out, snap)
        if expected
          gauge(out, 'wurk_swarm_children_expected', 'Children this swarm is configured to run.', [[nil, expected]])
        end
        gauge(out, 'wurk_swarm_children_fresh', 'Local processes with a heartbeat inside the ready window.',
              [[nil, fresh_local(snap, window, now).size]])
        rows = local_processes(snap)
        PROCESS_GAUGES.each do |name, help, value|
          samples = rows.filter_map do |row|
            reading = value.call(row, now)
            [{ 'pid' => row.pid.to_s }, reading] if reading
          end
          gauge(out, name, help, samples)
        end
      end

      def leader_gauge(out, snap)
        gauge(out, 'wurk_leader', '1 when this process group holds the leader lease.',
              [[nil, snap.leader && local?(snap.leader) ? 1 : 0]])
      end
    end
  end
end
