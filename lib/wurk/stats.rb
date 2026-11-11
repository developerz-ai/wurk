# frozen_string_literal: true

require 'date'
require_relative 'pool_checkout'
require_relative 'queue_consumers'

module Wurk
  # Read-only inspector for cluster state in Redis. The cheap counters are
  # eagerly pipelined at initialize so a single instance can answer many
  # questions without re-querying; the unbounded ones (`enqueued`,
  # `workers_size`, `queue_summaries`) re-fetch lazily.
  #
  # Wire-compat is sacred: every key matches the Sidekiq OSS schema exactly.
  # Spec: docs/target/sidekiq-free.md §19.1.
  class Stats
    # Sidekiq exposes this as a `Data` class. Third-party gems destructure on
    # `name`/`size`/`latency`/`paused?`, so the shape can't change.
    QueueSummary = Data.define(:name, :size, :latency, :paused) do
      alias_method :paused?, :paused
    end

    def initialize
      fetch_stats_fast!
    end

    def processed       = @stats.fetch(:processed)
    def failed          = @stats.fetch(:failed)
    def expired         = @stats.fetch(:expired)
    def scheduled_size  = @stats.fetch(:scheduled_size)
    def retry_size      = @stats.fetch(:retry_size)
    def dead_size       = @stats.fetch(:dead_size)
    def processes_size  = @stats.fetch(:processes_size)

    # Sum of LLEN across every known queue. Linear in queue count — the
    # spec labels this "slow" upstream; don't put it on a hot path.
    def enqueued
      queues.each_value.sum
    end

    # Sum of the `busy` HASH field across every live process identity.
    # Pipelined but unbounded by process count.
    def workers_size
      Wurk.redis(idempotent: true) do |conn|
        identities = conn.call('SMEMBERS', Keys::PROCESSES)
        next 0 if identities.empty?

        busy = conn.pipelined do |pipe|
          identities.each { |id| pipe.call('HGET', id, 'busy') }
        end
        busy.sum(&:to_i)
      end
    end

    # @return [Hash{String=>Integer}] queue name → LLEN, largest queue first.
    # `SMEMBERS` order is arbitrary; Sidekiq sorts the name/size pairs by size
    # descending before building the hash (Stats#queues, spec §19.1) — gems
    # and dashboards reading this rely on that order. Match it exactly with
    # `sort_by { |_, size| -size }`.
    def queues
      Wurk.redis(idempotent: true) do |conn|
        names = conn.call('SMEMBERS', Keys::QUEUES_SET)
        next {} if names.empty?

        sizes = conn.pipelined do |pipe|
          names.each { |q| pipe.call('LLEN', Keys.queue(q)) }
        end
        names.zip(sizes.map(&:to_i)).sort_by { |_, size| -size }.to_h
      end
    end

    # @return [Array<QueueSummary>] one per known queue, largest first.
    # Same size-descending order as Sidekiq's detailed queue list
    # (`queue_summaries.sort_by { |qd| -qd.size }`) — this feeds the
    # dashboard's queue table (api_controller#queues).
    def queue_summaries
      Wurk.redis(idempotent: true) do |conn|
        names = conn.call('SMEMBERS', Keys::QUEUES_SET)
        next [] if names.empty?

        paused_set = conn.call('SMEMBERS', 'paused').to_set
        results = conn.pipelined do |pipe|
          names.each do |q|
            pipe.call('LLEN', Keys.queue(q))
            pipe.call('LRANGE', Keys.queue(q), -1, -1)
          end
        end
        build_summaries(names, results, paused_set).sort_by { |qd| -qd.size }
      end
    end

    # Latency (secs) of the `default` queue — the most-asked-about gauge.
    def default_queue_latency
      now_ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
      payload = Wurk.redis(idempotent: true) { |c| c.call('LRANGE', Keys.queue('default'), -1, -1) }.first
      compute_latency(payload, now_ms)
    end

    # Resets the named global counters. With no args, clears `processed`,
    # `failed`, and `expired`. SET … 0 (not DEL — keeps the key around so
    # reads stay `Integer` not `nil`).
    #
    # The only write here, and the only block in this class that can't claim
    # apply-safety: a replay after a lost reply would re-zero the counters,
    # discarding whatever the fleet counted in between.
    def reset(*stats)
      all      = %w[failed processed expired]
      to_clear = stats.empty? ? all : all & stats.flatten.map(&:to_s)
      Wurk.redis do |conn|
        conn.pipelined do |pipe|
          to_clear.each { |s| pipe.call('SET', "stat:#{s}", 0) }
        end
      end
    end

    private

    # Single pipeline for the cheap counters. Eagerly invoked at initialize
    # so callers can read many fields without paying per-method round trips.
    FAST_QUERIES = [
      ['GET', 'stat:processed'],
      ['GET', 'stat:failed'],
      ['GET', Keys::STAT_EXPIRED],
      ['ZCARD', Keys::SCHEDULE],
      ['ZCARD', Keys::RETRY],
      ['ZCARD', Keys::DEAD],
      ['SCARD', Keys::PROCESSES]
    ].freeze
    FAST_KEYS = %i[processed failed expired scheduled_size retry_size dead_size processes_size].freeze
    private_constant :FAST_QUERIES, :FAST_KEYS

    def fetch_stats_fast!
      raw = Wurk.redis(idempotent: true) do |conn|
        conn.pipelined { |pipe| FAST_QUERIES.each { |args| pipe.call(*args) } }
      end
      @stats = FAST_KEYS.zip(raw.map(&:to_i)).to_h
    end

    def build_summaries(names, results, paused_set)
      now_ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
      names.each_with_index.map do |name, i|
        QueueSummary.new(
          name: name,
          size: results[i * 2].to_i,
          latency: compute_latency(results[(i * 2) + 1].first, now_ms),
          paused: paused_set.include?(name)
        )
      end
    end

    # `enqueued_at` may be Float (epoch secs, legacy) or Integer (epoch ms,
    # current). Spec §5 calls out the dual format; handle both. Like upstream's
    # calculate_latency, a payload without `enqueued_at` is timed from
    # `created_at`. Malformed JSON or a non-numeric stamp shouldn't crash a
    # dashboard read — fall back to 0.
    def compute_latency(payload_json, now_ms)
      return 0.0 if payload_json.nil?

      job = Wurk.load_json(payload_json)
      stamp = job['enqueued_at'] || job['created_at']
      return 0.0 if stamp.nil?

      enq = Float(stamp)
      enq_ms = enq < 10_000_000_000 ? enq * 1_000 : enq
      diff = (now_ms - enq_ms) / 1_000.0
      diff.negative? ? 0.0 : diff
    rescue ::JSON::ParserError, ::TypeError, ::ArgumentError
      0.0
    end

    # Every Stats reading taken at one moment, in two round trips: the
    # counters with the `queues`, `paused` and `processes` members, then each
    # queue's LLEN + tail and each process's `busy`. A plain Stats re-reads the
    # queue set per method and pays seven round trips for what the dashboard's
    # landing payload asks of it. Internal reader for the dashboard and the
    # HTTP API: Stats keeps Sidekiq's per-method reads (§19.1).
    #
    # `consumers: true` also reads each process's `info` and answers
    # #consumers, the per-queue subscriber count of QueueConsumers.counts.
    class Snapshot < Stats
      attr_reader :queue_summaries, :workers_size, :default_queue_latency

      def initialize(consumers: false) # rubocop:disable Lint/MissingSuper
        @with_consumers = consumers
        Wurk.redis(idempotent: true) do |conn|
          names, paused, identities = read_members(conn)
          read_gauges(conn, names, paused.to_set, identities)
        end
      end

      def enqueued = @queue_summaries.sum(&:size)
      def queues = @queue_summaries.to_h { |summary| [summary.name, summary.size] }

      # @return [Hash{String=>Integer}] queue → live subscribers.
      def consumers
        raise ArgumentError, 'Snapshot read without consumers: true' unless @with_consumers

        @consumers
      end

      private

      def read_members(conn)
        replies = conn.pipelined do |pipe|
          FAST_QUERIES.each { |args| pipe.call(*args) }
          pipe.call('SMEMBERS', Keys::QUEUES_SET)
          pipe.call('SMEMBERS', 'paused')
          pipe.call('SMEMBERS', Keys::PROCESSES)
        end
        @stats = FAST_KEYS.zip(replies.first(FAST_KEYS.size).map(&:to_i)).to_h
        replies.last(3)
      end

      # Queue replies first (LLEN, tail per queue), then the `default` tail when
      # that queue is not listed, then one reply per process.
      def read_gauges(conn, names, paused, identities)
        default_listed = names.include?('default')
        replies = conn.pipelined do |pipe|
          queue_commands(pipe, names, default_listed)
          identities.each { |id| process_command(pipe, id) }
        end
        queue_replies = replies.shift(names.size * 2)
        default_tail = default_listed ? queue_replies[(names.index('default') * 2) + 1] : replies.shift
        build_snapshot(names, queue_replies, paused, default_tail, replies)
      end

      def queue_commands(pipe, names, default_listed)
        names.each do |q|
          pipe.call('LLEN', Keys.queue(q))
          pipe.call('LRANGE', Keys.queue(q), -1, -1)
        end
        pipe.call('LRANGE', Keys.queue('default'), -1, -1) unless default_listed
      end

      def process_command(pipe, identity)
        return pipe.call('HGET', identity, 'busy') unless @with_consumers

        pipe.call('HMGET', identity, 'busy', 'info')
      end

      def build_snapshot(names, queue_replies, paused, default_tail, process_replies)
        @queue_summaries = build_summaries(names, queue_replies, paused).sort_by { |qd| -qd.size }
        now_ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
        @default_queue_latency = compute_latency(default_tail.first, now_ms)
        if @with_consumers
          @workers_size = process_replies.sum { |busy, _| busy.to_i }
          @consumers = QueueConsumers.tally(process_replies.map(&:last))
        else
          @workers_size = process_replies.sum(&:to_i)
        end
      end
    end

    # Per-day historical processed/failed/expired counts. Reads
    # `stat:processed:YYYY-MM-DD`, `stat:failed:YYYY-MM-DD`, and
    # `stat:expired:YYYY-MM-DD` strings; missing days return 0. Range
    # 1..1825 (5 years) mirrors upstream.
    class History
      MAX_DAYS = 1_825

      def initialize(days_previous, start_date = nil, pool: nil)
        raise ArgumentError, "days_previous must be in 1..#{MAX_DAYS}" unless (1..MAX_DAYS).cover?(days_previous)

        @days_previous = days_previous
        # UTC, not `Date.today`: the writer (Launcher#write_stats) keys these
        # buckets off `Time.now.utc`, so a local civil date reads a day the
        # writer never wrote for whatever slice of each day the host's offset
        # spans — the newest bucket comes back 0 and the window is shifted.
        @start_date    = start_date || ::Time.now.utc.to_date
        @pool          = pool
      end

      def processed = date_stat_hash('processed')
      def failed    = date_stat_hash('failed')
      def expired   = date_stat_hash('expired')

      private

      def date_stat_hash(stat)
        keys = (0...@days_previous).map { |i| (@start_date - i).strftime('%Y-%m-%d') }
        values = with_redis(idempotent: true) do |conn|
          conn.pipelined { |pipe| keys.each { |d| pipe.call('GET', "stat:#{stat}:#{d}") } }
        end
        keys.zip(values.map(&:to_i)).to_h
      end

      def with_redis(idempotent: false, &)
        if @pool
          PoolCheckout.with(@pool, idempotent, &)
        else
          Wurk.redis(idempotent:, &)
        end
      end
    end
  end
end
