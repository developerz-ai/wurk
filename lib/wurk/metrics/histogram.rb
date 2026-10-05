# frozen_string_literal: true

module Wurk
  module Metrics
    # Per-class, per-minute execution-time histogram — Sidekiq 8.1's
    # `Sidekiq::Metrics::Histogram` wire format, so `Query#for_job` reads
    # histograms Sidekiq wrote before a swap and Sidekiq's Web UI reads ours
    # after a rollback:
    #
    #   h|<klass>-<D>-<H>:<M>   BITFIELD of 26 u16 counters, TTL 8h
    #
    # `<D>-<H>:<M>` is the UTC day-of-month / hour / minute, all unpadded.
    # Successful executions only (Sidekiq does not time failed jobs). Wurk
    # counts in Metrics::Accumulator, History.flush writes the BITFIELD and
    # Query#for_job reads it, so this owns only the bucket layout and key.
    module Histogram
      # Upper bound (exclusive, ms) of each bucket; the last catches the rest.
      BUCKET_INTERVALS = [
        20, 30, 45, 65, 100,
        150, 225, 335, 500, 750,
        1100, 1700, 2500, 3800, 5750,
        8500, 13_000, 20_000, 30_000, 45_000,
        65_000, 100_000, 150_000, 225_000, 335_000,
        1e20
      ].freeze
      LABELS = %w[
        20ms 30ms 45ms 65ms 100ms
        150ms 225ms 335ms 500ms 750ms
        1.1s 1.7s 2.5s 3.8s 5.75s
        8.5s 13s 20s 30s 45s
        65s 100s 150s 225s 335s
        Slow
      ].freeze
      SIZE = BUCKET_INTERVALS.size
      FETCH = (0...SIZE).flat_map { |i| ['GET', 'u16', "##{i}"] }.freeze
      HISTOGRAM_TTL = 8 * 60 * 60

      def self.index_for(ms)
        BUCKET_INTERVALS.index { |ceiling| ms < ceiling }
      end

      def self.key(klass, time)
        "h|#{klass}-#{time.utc.strftime('%-d-%-H:%-M')}"
      end

      # `BITFIELD key OVERFLOW SAT INCRBY u16 #i n …` for the non-zero counters.
      def self.incr_command(klass, time, counts)
        cmd = ['BITFIELD', key(klass, time), 'OVERFLOW', 'SAT']
        counts.each_with_index { |n, i| cmd.push('INCRBY', 'u16', "##{i}", n) if n.positive? }
        cmd
      end
    end
  end
end
