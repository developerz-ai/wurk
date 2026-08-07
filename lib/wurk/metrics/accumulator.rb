# frozen_string_literal: true

module Wurk
  module Metrics
    # The in-memory half of Wurk::Metrics::History. Every execution folds into a
    # `{pool => {minute => {class => [processed, failed, ms]}}}` tree under one
    # mutex; Wurk::Metrics::Flusher drains it into Redis on a timer. `HINCRBY`
    # is additive, so N folded executions leave Redis in the same state as the N
    # individual pipelines the hot path used to send.
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
        @lock.synchronize do
          counts = (((@pools[pool] ||= {})[minute] ||= {})[klass] ||= [0, 0, 0])
          counts[success ? 0 : 1] += 1
          counts[2] += ms
        end
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

      def merge_minute(into, minute, classes)
        target = (into[minute] ||= {})
        classes.each do |klass, counts|
          existing = target[klass]
          if existing
            counts.each_with_index { |count, i| existing[i] += count }
          else
            target[klass] = counts
          end
        end
      end

      def trim(minutes)
        excess = minutes.size - MAX_RETAINED_MINUTES
        return if excess <= 0

        minutes.keys.min(excess).each { |minute| minutes.delete(minute) }
      end
    end
  end
end
