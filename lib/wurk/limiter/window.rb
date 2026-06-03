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
        cutoff = ::Time.now.to_f - interval_seconds
        Wurk::Limiter.redis do |c|
          c.call('ZREMRANGEBYSCORE', state_key, '-inf', "(#{cutoff}")
          c.call('ZCARD', state_key).to_i
        end
      end

      # used = entries still inside the window; limit = count; reset_at =
      # when the oldest entry slides out (freeing a slot), or nil when
      # idle (#16).
      def status
        build_status(used: size, limit: @options[:count], reset_at: oldest_expiry)
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

      # Oldest timestamp + interval = the moment it leaves the window.
      def oldest_expiry
        row = Wurk::Limiter.redis { |c| c.call('ZRANGE', state_key, 0, 0, 'WITHSCORES') }
        score = Wurk::Limiter.first_score(row)
        score && (score + interval_seconds)
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
