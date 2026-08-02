# frozen_string_literal: true

require_relative 'base'

module Wurk
  module Limiter
    # Sliding window via ZSET of timestamps. Accepts symbolic units or a
    # raw Integer (in seconds). Used-units expand to N ZADDs in the Lua
    # script so multi-charge calls remain atomic.
    class Window < Base
      WAIT_SLEEP = 0.5

      def type = :window

      def initialize(name, **options)
        # Symbol or raw Integer (spec §1.2: window accepts both).
        Limiter.interval_seconds(options[:interval], allow_integer: true)
        super
      end

      def size
        window_state.first
      end

      # used = entries still inside the window; limit = count; reset_at =
      # when the oldest entry slides out (freeing a slot), or nil when
      # idle (#16).
      def status
        used, oldest = window_state
        build_status(used: used, limit: @options[:count], reset_at: oldest && (oldest + interval_seconds))
      end

      def within_limit(used: 1, &block)
        raise ArgumentError, 'block required' unless block

        deadline = ::Time.now.to_f + @options[:wait_timeout]
        loop do
          ok, _current, _oldest = acquire(used)
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
        "lmtr-w:#{@name}"
      end

      # Count + oldest in-window score, both scoped by the Redis clock, in one
      # read-only round trip. Reads never trim (the acquire script owns that):
      # a dashboard host whose clock ran ahead used to evict live entries just
      # by rendering `status`, freeing the window for a second full charge.
      # Oldest timestamp + interval = the moment it leaves the window; -1 =
      # nothing in window.
      def window_state
        count, oldest = lua(:limiter_window_status, keys: [state_key], argv: [interval_seconds])
        score = oldest.to_f
        [count.to_i, score.negative? ? nil : score]
      end

      def interval_seconds
        @interval_seconds ||= Limiter.interval_seconds(@options[:interval], allow_integer: true)
      end

      def acquire(used)
        lua(:limiter_window_acquire,
            keys: [state_key],
            argv: [@options[:count], interval_seconds, used, ttl, random_id])
      end
    end
  end
end
