# frozen_string_literal: true

require_relative '../component'
require_relative '../keys'
require_relative '../job_record'
require_relative '../timer_loop'
require_relative 'rollup'

module Wurk
  module Metrics
    # Leader-only background thread that snapshots each queue's current depth
    # (LLEN) and head-of-line latency into compact per-queue gauge buckets the
    # dashboard's "queue size / latency over time" charts read directly:
    #
    #   qm|1m|<epoch>   HASH {<queue>|sz, <queue>|lt}   TTL 24h
    #   qm|5m|<epoch>   HASH {<queue>|sz, <queue>|lt}   TTL 7d
    #   qm|1h|<epoch>   HASH {<queue>|sz, <queue>|lt}   TTL 30d
    #
    # Unlike Metrics::Rollup (which SUMS counters rolled up from a source),
    # size and latency are GAUGES — point-in-time values — so each tick samples
    # "now" and writes it to the current bucket at every resolution. Within a
    # coarse (5m/1h) bucket the per-minute ticks overwrite, so the bucket holds
    # the latest sample in its window (a "last value" downsample, which is the
    # right summary for a gauge). Leader-gated so N workers don't each sample
    # the same queues every minute. `<epoch>` is the UTC start-of-bucket.
    #
    # Spec: docs/target/sidekiq-ent.md §5.2 (sidekiq.queue.size /
    # sidekiq.queue.latency gauges), §7 Historical tab.
    class QueueRollup
      include Component

      PREFIX = 'qm'
      SIZE_KIND = 'sz'
      LAT_KIND = 'lt'

      # Mirror Metrics::Rollup retention so the dashboard's range selector
      # (24h·1m / 7d·5m / 30d·1h) maps 1:1 to both the throughput and the
      # queue-gauge series.
      BUCKETS = Wurk::Metrics::Rollup::BUCKETS

      DEFAULT_TICK_SECONDS = 60

      def self.bucket_key(bucket, epoch)
        "#{PREFIX}|#{bucket}|#{epoch}"
      end

      def initialize(config)
        @config = config
        @timer = TimerLoop.new(config[:metrics_rollup_interval] || DEFAULT_TICK_SECONDS)
        @thread = nil
      end

      def start
        return @thread if @thread

        @timer.reset
        @thread = safe_thread('queue-metrics') { @timer.run { tick } }
      end

      # Blocks until the thread is really gone: the launcher releases the
      # cluster lock immediately after this returns, and a sample still in
      # flight would write the same buckets as the next leader's first one.
      #
      # Cleared only on a confirmed join (Thread#join returns nil on timeout):
      # a wedged thread must stay tracked so #start's guard returns it instead
      # of calling @timer.reset, which would un-terminate the loop it is still
      # inside and leave two threads HSETting the same buckets.
      def terminate
        @timer.terminate
        @thread = nil if @thread&.join(TimerLoop::JOIN_TIMEOUT)
      end

      # Leader-gated: only the elected leader samples, so N workers don't each
      # HSET the same buckets every minute.
      def tick(now: ::Time.now)
        return unless leader?

        sample(now)
      rescue StandardError => e
        handle_exception(e, { context: 'queue-metrics' })
      end

      # One sampling pass, bypassing the leader gate and the sleep loop. Public
      # so deterministic specs and a manual "sample now" can drive it directly.
      #
      # A zero gauge is not stored: readers default a missing field to 0, and
      # an idle fleet's queues are mostly empty, so storing them cost two
      # fields per queue in every bucket for nothing. It is HDEL'd instead of
      # skipped, so a queue that drained inside a coarse bucket reads 0 there
      # rather than keeping the earlier sample. All three buckets go in one
      # pipeline.
      def sample(now = ::Time.now)
        gauges = queue_gauges
        return if gauges.empty?

        set, zero = gauge_fields(gauges)
        keys = bucket_keys(now)
        redis { |c| c.pipelined { |p| keys.each { |key, ttl| write_bucket(p, key, ttl, set, zero) } } }
        nil
      end

      private

      # [[bucket key, ttl], ...] for the bucket `now` falls in at each resolution.
      def bucket_keys(now)
        BUCKETS.map { |bucket, (step, ttl)| [self.class.bucket_key(bucket, (now.to_i / step) * step), ttl] }
      end

      def write_bucket(pipe, key, ttl, set, zero)
        pipe.call('HSET', key, *set) unless set.empty?
        pipe.call('HDEL', key, *zero) unless zero.empty?
        pipe.call('EXPIRE', key, ttl)
      end

      # [flat field/value pairs to HSET, fields to HDEL], zero gauges in the
      # second list.
      def gauge_fields(gauges)
        set = []
        zero = []
        gauges.each do |name, (size, lat)|
          size.zero? ? zero << "#{name}|#{SIZE_KIND}" : set.push("#{name}|#{SIZE_KIND}", size)
          lat.zero? ? zero << "#{name}|#{LAT_KIND}" : set.push("#{name}|#{LAT_KIND}", lat)
        end
        [set, zero]
      end

      # [[queue_name, [size, latency_seconds]], ...] for every live queue. The
      # latency is the head-of-line wait — the tail of the LIST is the oldest
      # job — in seconds, rounded for compact storage.
      def queue_gauges
        now_ms = real_ms
        redis do |c|
          names = c.call('SMEMBERS', Keys::QUEUES_SET)
          next [] if names.empty?

          raw = pipelined_queue_reads(c, names)
          names.each_with_index.map do |name, i|
            [name, [raw[i * 2].to_i, head_latency(raw[(i * 2) + 1], now_ms)]]
          end
        end
      end

      # Per queue: LLEN (depth) then LRANGE tail (head-of-line job), in one
      # round trip. Results interleave [len, [tail], len, [tail], …].
      def pipelined_queue_reads(conn, names)
        conn.pipelined do |p|
          names.each do |q|
            p.call('LLEN', Keys.queue(q))
            p.call('LRANGE', Keys.queue(q), -1, -1)
          end
        end
      end

      # A single malformed tail payload (bad JSON, or valid JSON of the wrong
      # shape) yields 0.0 for that queue rather than bubbling up and skipping
      # the whole sampling pass for every queue.
      def head_latency(lrange_result, now_ms)
        payload = lrange_result.is_a?(::Array) ? lrange_result.first : lrange_result
        return 0.0 if payload.nil?

        parsed = Wurk.load_json(payload)
        enqueued_at = parsed.is_a?(::Hash) ? parsed['enqueued_at'] : nil
        Wurk::JobRecord.latency_from(enqueued_at, now_ms).round(2)
      rescue ::JSON::ParserError, ::TypeError, ::ArgumentError
        0.0
      end
    end
  end
end
