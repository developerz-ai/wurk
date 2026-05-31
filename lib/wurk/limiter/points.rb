# frozen_string_literal: true

require_relative 'base'

module Wurk
  module Limiter
    # Token-bucket with explicit `estimate:` per call. Refills at
    # `refill_per_second` capped at `initial_points`. Failure mode is
    # immediate (spec §1.4 — no sleep loop). The block is invoked with a
    # `Handle` so user code may refund/over-charge via `handle.points_used`.
    class Points < Base
      class Handle
        def initialize(limiter, estimate)
          @limiter = limiter
          @estimate = estimate
        end

        # Positive delta returns points to the bucket; negative records an
        # under-estimate. Either way, clamped to [0, cap].
        def points_used(actual)
          delta = @estimate - actual
          @limiter.send(:refund, delta)
        end
      end

      def type = :points

      # Apply refill on read so the size matches what the *next* acquire
      # would see. Stored balance only updates on acquire/refund; without
      # this, a fully-refilled bucket reports stale low numbers.
      def size
        cap = @options[:initial].to_f
        data = Wurk::Limiter.redis { |c| c.call('HMGET', state_key, 'points', 'last') }
        stored = data[0]
        return cap if stored.nil?

        last = (data[1] || ::Time.now.to_f).to_f
        elapsed = [::Time.now.to_f - last, 0.0].max
        [cap, stored.to_f + (elapsed * @options[:refill].to_f)].min
      end

      # used = points consumed (cap − available); limit = the cap; reset_at =
      # when the bucket refills to full, or nil when already full (#16).
      def status
        cap = @options[:initial].to_f
        available = size
        used = cap - available
        refill = @options[:refill].to_f
        reset_at = available < cap && refill.positive? ? ::Time.now.to_f + ((cap - available) / refill) : nil
        build_status(used: used, limit: cap, reset_at: reset_at)
      end

      def within_limit(estimate:, &block)
        raise ArgumentError, 'block required' unless block
        raise ArgumentError, 'estimate must be positive' if estimate <= 0

        ok, _remaining = acquire(estimate)
        raise OverLimit, self unless ok.to_i == 1

        handle = Handle.new(self, estimate)
        block.call(handle)
      end

      protected

      def state_keys
        [state_key]
      end

      private

      def state_key
        "lmtr-p:#{@name}"
      end

      def acquire(estimate)
        lua(:limiter_points_acquire,
            keys: [state_key],
            argv: [@options[:initial], @options[:refill], estimate, ttl])
      end

      def refund(delta)
        lua(:limiter_points_refund,
            keys: [state_key],
            argv: [delta, @options[:initial], ttl]).to_f
      end
    end
  end
end
