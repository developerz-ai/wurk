# frozen_string_literal: true

require_relative 'base'

module Wurk
  module Limiter
    # Atomic slot acquisition in a ZSET. Score = expiry epoch; the acquire
    # script first evicts expired slots (bumping the `reclaimed` metric)
    # then ZADDs if there's headroom (bumping the `held` metric).
    #
    # On exhaustion: spin loop with backoff. The spec says "blocks via
    # Redis stream XREAD" — that's a perf optimization; the visible
    # behavior is identical: blocks up to `wait_timeout` then OverLimit
    # (or silent return for `policy: :ignore`).
    class Concurrent < Base
      WAIT_SLEEP = 0.05

      METRIC_FIELDS = %w[held held_time immediate waited wait_time overages reclaimed].freeze

      def type = :concurrent

      def size
        Wurk::Limiter.redis { |c| c.call('ZCARD', state_key).to_i }
      end

      # Uniform `{ used:, limit:, reset_at:, available? }` (#16) merged with
      # the concurrent-only metric counters (§1.5) the dashboard already
      # renders. Slots free on release rather than on a clock, so `reset_at`
      # is the soonest in-flight slot expiry (a worst-case "available by"),
      # or nil when idle.
      def status
        used = size
        build_status(used: used, limit: @options[:limit], reset_at: soonest_expiry)
          .merge(metrics)
      end

      def within_limit(&block)
        raise ArgumentError, 'block required' unless block

        started = monotime
        slot = random_id
        acquired_at = wait_for_slot(slot, started + @options[:wait_timeout])
        return unless acquired_at

        begin
          incr_immediate_or_waited(acquired_at - started)
          block.call
        ensure
          record_release(slot, acquired_at)
        end
      end

      protected

      def state_keys
        [state_key, stats_key]
      end

      private

      def metrics
        h = Wurk::Limiter.redis { |c| c.call('HGETALL', stats_key) }
        # redis-client returns either a flat array or a hash depending on
        # the server version — normalize once so callers always see a hash.
        h = h.each_slice(2).to_h if h.is_a?(Array)
        METRIC_FIELDS.to_h { |k| [k, (h[k] || '0').to_i] }
      end

      # Lowest slot expiry epoch (the next slot to free), or nil when empty.
      def soonest_expiry
        row = Wurk::Limiter.redis { |c| c.call('ZRANGE', state_key, 0, 0, 'WITHSCORES') }
        Wurk::Limiter.first_score(row)
      end

      def state_key
        "lmtr-cs:#{@name}"
      end

      def stats_key
        "lmtr-stats:#{@name}"
      end

      # A ZREM that removes nothing means an acquirer already evicted our slot:
      # we outran `lock_timeout`, which is what `overages` counts. Exhausting
      # `wait_timeout` is a different event — it raises OverLimit and the server
      # middleware counts it in the job's `overrated` field.
      def record_release(slot, acquired_at)
        bump_counter('overages') if release(slot).to_i.zero?
        bump_counter('held_time', (monotime - acquired_at).to_i)
      end

      # Spins until a slot frees up. Returns the monotonic acquire time, nil
      # when `policy: :ignore` gives up; raises OverLimit past `wait_timeout`.
      def wait_for_slot(slot, deadline)
        loop do
          return monotime if acquire(slot)[0].to_i == 1
          return if @options[:policy] == :ignore

          remaining = deadline - monotime
          raise OverLimit, self if remaining <= 0

          sleep [remaining, WAIT_SLEEP].min
        end
      end

      def acquire(slot)
        lua(:limiter_concurrent_acquire,
            keys: [state_key, stats_key],
            argv: [@options[:limit], @options[:lock_timeout], slot, ttl])
      end

      def release(slot)
        lua(:limiter_concurrent_release, keys: [state_key], argv: [slot])
      end

      def bump_counter(field, by = 1)
        Wurk::Limiter.redis do |c|
          c.call('HINCRBY', stats_key, field, by)
          c.call('EXPIRE', stats_key, ttl)
        end
      end

      def incr_immediate_or_waited(elapsed)
        if elapsed < WAIT_SLEEP
          bump_counter('immediate')
        else
          bump_counter('waited')
          bump_counter('wait_time', elapsed.to_i)
        end
      end

      def monotime
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
