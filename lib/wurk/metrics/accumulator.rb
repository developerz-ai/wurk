# frozen_string_literal: true

require_relative 'histogram'

module Wurk
  module Metrics
    # The in-memory half of Wurk::Metrics::History. Every execution folds into a
    # `{pool => {minute => {class => [processed, failed, ms, histogram]}}}` tree
    # under one mutex; Wurk::Metrics::Flusher drains it into Redis on a timer.
    # `HINCRBY` / `BITFIELD INCRBY` are additive, so N folded executions leave
    # Redis in the same state as N individual writes.
    #
    # Counting follows Sidekiq's ExecutionTracker: `processed` counts every
    # execution, `failed` the ones that raised, and `ms` plus the histogram
    # (an Array of Histogram::SIZE counters, nil until the first success) only
    # the ones that did not — a failed job's runtime is noise.
    #
    # Knows nothing about Redis — History owns the write, this owns the counts.
    #
    # The minute is the bucket the job *ran* in, decided by the caller at record
    # time. That is what keeps the batching a visibility lag instead of a
    # misattribution: a job that runs at 12:03:59 and flushes at 12:04:02 still
    # counts toward 12:03. Signed off in
    # docs/plans/2026/08/06/101-faster-than-sidekiq/00-semantics-signoff.md §2.
    #
    # Keyed by the pool the recording middleware handed us (nil = the process
    # default), so a multi-capsule process flushes each capsule's counts through
    # the pool that capsule's jobs ran on.
    class Accumulator
      # Ceiling on minute buckets retained per pool. Only reachable through
      # #merge_back: a flush that keeps failing puts its counts back every tick,
      # and a Redis outage that outlives the process would otherwise grow a
      # structure fed by the job hot path without bound. The newest buckets win
      # — they are the ones the dashboard is still drawing — and the oldest are
      # dropped, which these counters have always been allowed to do (a Redis
      # failure during a metrics write has never changed a job's outcome).
      MAX_RETAINED_MINUTES = 60

      def initialize
        @lock = ::Mutex.new
        @pools = {}
      end

      # Hot path. Three hash lookups under the mutex; allocates only the first
      # time a (pool, minute, class) triple is seen.
      def add(pool, klass, minute, ms, success)
        bucket = Histogram.index_for(ms) if success
        @lock.synchronize { fold(((@pools[pool] ||= {})[minute] ||= {})[klass] ||= [0, 0, 0, nil], ms, bucket) }
      end

      # Hands the whole tree over and starts a fresh one, so recording never
      # blocks behind the flush's Redis round trip.
      def drain
        @lock.synchronize do
          drained = @pools
          @pools = {}
          drained
        end
      end

      # Puts one pool's counts back after its write failed, so the next tick
      # retries them instead of dropping the window. Merged rather than
      # assigned: jobs kept recording into the fresh tree while the flush was in
      # flight, and those counts have not been written yet either.
      def merge_back(pool, minutes)
        @lock.synchronize do
          into = (@pools[pool] ||= {})
          minutes.each { |minute, classes| merge_minute(into, minute, classes) }
          trim(into)
        end
      end

      def empty?
        @lock.synchronize { @pools.empty? }
      end

      private

      # `bucket` is the success's histogram slot, nil for a failure.
      def fold(counts, ms, bucket)
        counts[0] += 1
        return counts[1] += 1 unless bucket

        counts[2] += ms
        (counts[3] ||= Array.new(Histogram::SIZE, 0))[bucket] += 1
      end

      def merge_minute(into, minute, classes)
        target = (into[minute] ||= {})
        classes.each do |klass, counts|
          existing = target[klass]
          if existing
            merge_counts(existing, counts)
          else
            target[klass] = counts
          end
        end
      end

      def merge_counts(into, counts)
        3.times { |i| into[i] += counts[i] }
        return unless counts[3]

        hist = (into[3] ||= Array.new(Histogram::SIZE, 0))
        counts[3].each_with_index { |n, i| hist[i] += n }
      end

      def trim(minutes)
        excess = minutes.size - MAX_RETAINED_MINUTES
        return if excess <= 0

        minutes.keys.min(excess).each { |minute| minutes.delete(minute) }
      end
    end
  end
end
