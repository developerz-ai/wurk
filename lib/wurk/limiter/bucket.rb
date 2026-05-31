# frozen_string_literal: true

require_relative 'base'

module Wurk
  module Limiter
    # Cardinal-boundary counter. Reset at the top of the unit (00:00 of
    # minute/hour/day). On exhaustion sleep until next boundary, retry,
    # OverLimit if that exceeds wait_timeout.
    class Bucket < Base
      def type = :bucket

      def initialize(name, **options)
        # Eager interval validation so a typo in `:fortnight` blows up at boot,
        # not at first call. Lazy validation defers failures to runtime.
        Limiter.interval_seconds(options[:interval], allow_integer: false)
        super
      end

      def size
        Wurk::Limiter.redis { |c| (c.call('GET', epoch_key) || '0').to_i }
      end

      # used = this period's count; limit = count; reset_at = the next
      # cardinal boundary, when the counter rolls back to zero (#16).
      def status
        build_status(used: size, limit: @options[:count], reset_at: next_boundary)
      end

      def within_limit(used: 1, &block)
        raise ArgumentError, 'block required' unless block

        deadline = ::Time.now.to_f + @options[:wait_timeout]
        loop do
          ok, _current, secs_to_next = acquire(used)
          return block.call if ok.to_i == 1

          remaining = deadline - ::Time.now.to_f
          raise OverLimit, self if remaining <= 0

          sleep [remaining, secs_to_next.to_f, 0.05].compact.min.clamp(0.0, remaining)
        end
      end

      protected

      def state_keys
        # Bucket keys are per-epoch and self-expiring; reset wipes the
        # current epoch, the only one a caller could care about. Older
        # epochs already EXPIRE'd.
        epoch = ::Time.now.to_i / interval_seconds
        ["lmtr-b:#{@name}:#{epoch}"]
      end

      private

      def epoch_index
        ::Time.now.to_i / interval_seconds
      end

      def epoch_key
        "lmtr-b:#{@name}:#{epoch_index}"
      end

      def next_boundary
        (epoch_index + 1).to_f * interval_seconds
      end

      def interval_seconds
        @interval_seconds ||= Limiter.interval_seconds(@options[:interval], allow_integer: false)
      end

      def acquire(used)
        lua(:limiter_bucket_acquire,
            keys: ["lmtr-b:#{@name}"],
            argv: [@options[:count], interval_seconds, used, ttl])
      end
    end
  end
end
