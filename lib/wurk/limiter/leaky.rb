# frozen_string_literal: true

require_relative 'base'

module Wurk
  module Limiter
    # Leaky bucket: drain rate = bucket_size / drain ops/sec. Stored as a
    # HASH of {level, last} — Lua compares level vs bucket_size after
    # leaking elapsed * drain_per_sec.
    class Leaky < Base
      WAIT_SLEEP = 0.05

      def type = :leaky

      def size
        h = Wurk::Limiter.redis { |c| c.call('HGET', state_key, 'level') }
        h.to_f
      end

      # used = current fill level; limit = bucket_size; reset_at = when the
      # steady drip frees a slot (only meaningful while full), else nil (#16).
      def status
        level = size
        cap = @options[:bucket_size]
        reset_at = level >= cap ? ::Time.now.to_f + ((level - cap + 1) / drain_per_sec) : nil
        build_status(used: level, limit: cap, reset_at: reset_at)
      end

      def within_limit(&block)
        raise ArgumentError, 'block required' unless block

        deadline = ::Time.now.to_f + @options[:wait_timeout]
        loop do
          ok, _level = acquire
          return block.call if ok.to_i == 1

          remaining = deadline - ::Time.now.to_f
          raise OverLimit, self if remaining <= 0

          sleep [remaining, WAIT_SLEEP].min
        end
      end

      protected

      def state_keys
        [state_key]
      end

      private

      def state_key
        "lmtr-l:#{@name}"
      end

      def drain_interval_seconds
        case @options[:drain]
        when Symbol
          Limiter.interval_seconds(@options[:drain], allow_integer: false)
        when Integer
          raise ArgumentError, "drain must be > 0 (got #{@options[:drain]})" unless @options[:drain].positive?

          @options[:drain]
        else
          raise ArgumentError, "drain must be Symbol or Integer (got #{@options[:drain].class})"
        end
      end

      # bucket_size / drain → ops per second. A zero/negative bucket_size would
      # silently produce a non-positive rate (and a 1/0 in `status` reset_at);
      # fail fast at the boundary so callers see the bad config, not a NaN.
      def drain_per_sec
        @drain_per_sec ||= begin
          rate = @options[:bucket_size].to_f / drain_interval_seconds
          unless rate.positive?
            raise ArgumentError,
                  "drain_per_sec must be > 0 (bucket_size=#{@options[:bucket_size]}, drain=#{@options[:drain]})"
          end

          rate
        end
      end

      def acquire
        lua(:limiter_leaky_acquire,
            keys: [state_key],
            argv: [@options[:bucket_size], drain_per_sec, ttl])
      end
    end
  end
end
