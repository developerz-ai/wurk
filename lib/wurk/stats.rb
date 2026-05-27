# frozen_string_literal: true

require 'date'

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
      Wurk.redis do |conn|
        identities = conn.call('SMEMBERS', Keys::PROCESSES)
        next 0 if identities.empty?

        busy = conn.pipelined do |pipe|
          identities.each { |id| pipe.call('HGET', id, 'busy') }
        end
        busy.sum(&:to_i)
      end
    end

    # @return [Hash{String=>Integer}] queue name → LLEN.
    def queues
      Wurk.redis do |conn|
        names = conn.call('SMEMBERS', Keys::QUEUES_SET)
        next {} if names.empty?

        sizes = conn.pipelined do |pipe|
          names.each { |q| pipe.call('LLEN', Keys.queue(q)) }
        end
        names.zip(sizes.map(&:to_i)).to_h
      end
    end

    # @return [Array<QueueSummary>] one per known queue.
    def queue_summaries
      Wurk.redis do |conn|
        names = conn.call('SMEMBERS', Keys::QUEUES_SET)
        next [] if names.empty?

        paused_set = conn.call('SMEMBERS', 'paused')
        results = conn.pipelined do |pipe|
          names.each do |q|
            pipe.call('LLEN', Keys.queue(q))
            pipe.call('LRANGE', Keys.queue(q), -1, -1)
          end
        end
        build_summaries(names, results, paused_set)
      end
    end

    # Latency (secs) of the `default` queue — the most-asked-about gauge.
    def default_queue_latency
      now_ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
      payload = Wurk.redis { |c| c.call('LRANGE', Keys.queue('default'), -1, -1) }.first
      compute_latency(payload, now_ms)
    end

    # Resets the named global counters. With no args, clears `processed`,
    # `failed`, and `expired`. SET … 0 (not DEL — keeps the key around so
    # reads stay `Integer` not `nil`).
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
      ['GET',   'stat:processed'],
      ['GET',   'stat:failed'],
      ['GET',   Keys::STAT_EXPIRED],
      ['ZCARD', Keys::SCHEDULE],
      ['ZCARD', Keys::RETRY],
      ['ZCARD', Keys::DEAD],
      ['SCARD', Keys::PROCESSES]
    ].freeze
    FAST_KEYS = %i[processed failed expired scheduled_size retry_size dead_size processes_size].freeze
    private_constant :FAST_QUERIES, :FAST_KEYS

    def fetch_stats_fast!
      raw = Wurk.redis do |conn|
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
    # current). Spec §5 calls out the dual format; handle both. Malformed
    # JSON or non-numeric `enqueued_at` shouldn't crash a dashboard read —
    # fall back to 0.
    def compute_latency(payload_json, now_ms)
      return 0.0 if payload_json.nil?

      enq = Float(Wurk.load_json(payload_json)['enqueued_at'] || 0)
      enq_ms = enq < 10_000_000_000 ? enq * 1_000 : enq
      diff = (now_ms - enq_ms) / 1_000.0
      diff.negative? ? 0.0 : diff
    rescue ::JSON::ParserError, ::TypeError, ::ArgumentError
      0.0
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
        @start_date    = start_date || ::Date.today
        @pool          = pool
      end

      def processed = date_stat_hash('processed')
      def failed    = date_stat_hash('failed')
      def expired   = date_stat_hash('expired')

      private

      def date_stat_hash(stat)
        keys = (0...@days_previous).map { |i| (@start_date - i).strftime('%Y-%m-%d') }
        values = with_redis do |conn|
          conn.pipelined { |pipe| keys.each { |d| pipe.call('GET', "stat:#{stat}:#{d}") } }
        end
        keys.zip(values.map(&:to_i)).to_h
      end

      def with_redis(&)
        if @pool
          @pool.with(&)
        else
          Wurk.redis(&)
        end
      end
    end
  end
end
