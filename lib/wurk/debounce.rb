# frozen_string_literal: true

require_relative 'job_util'
require_relative 'keys'
require_relative 'lua'
require_relative 'pool_checkout'
require_relative 'unique'

module Wurk
  # Debounce — collapse a burst of enqueues into one job carrying the last
  # payload, fired after a period of quiet. A Wurk extra, not a Sidekiq
  # surface, and deliberately not a second flavour of {Wurk::Unique}: unique
  # *rejects* the duplicate and keeps the first, debounce *replaces* the
  # pending job and keeps the last.
  #
  # The classic use is a re-derivation triggered by something a user does
  # repeatedly — reindex a record, warm a cache, recompute a projection. Fifty
  # edits in a minute should produce one rebuild at the end, not fifty.
  #
  # Redis schema — one new key, plus an ordinary entry in the ZSET that already
  # exists:
  #
  #   debounce:<digest>   HASH   member (the pending job JSON), first (epoch)
  #   schedule            ZSET   the collapsed job, exactly as `perform_in`
  #                              would have written it
  #
  # Nothing reading `schedule` can tell a debounced job from any other
  # scheduled one — {Wurk::ScheduledSet}, the dashboard and a stock Sidekiq
  # poller all handle it unchanged. There is no parallel delayed structure.
  #
  # Identity is {Wurk::Unique}'s digest of `[class, queue, args]`, so a class
  # that already narrows its key with `sidekiq_unique_context` narrows its
  # debounce key the same way — that hook is the supported "collapse on a
  # subset of the args" escape hatch, and there is no second one.
  module Debounce
    # How long `debounce:<digest>` outlives the entry it points at.
    #
    # The key's only job is to remember which member to pull back out of
    # `schedule` when the burst is extended, so it must not expire while that
    # member is still pending — a burst that lost its key ZADDs a second entry
    # next to the first and stops collapsing. The window that matters is
    # therefore "fire time → poller promotes it", which the scheduler keeps at
    # roughly `average_scheduled_poll_interval` across the cluster however many
    # processes are running. Five minutes is far past that; overshooting costs
    # one ~100-byte key per idle debounce identity, and the script treats an
    # outlived key as a finished burst anyway.
    GRACE = 300

    # What one debounced enqueue did to the pending entry.
    #
    # `replaced` is the only part a caller cannot work out for itself: from
    # outside the script, extending a live burst and opening a new one look
    # identical. `at` is the epoch second the job will run — capped, so it is
    # not necessarily `now + wait`. `opened_at` is the burst's own start, the
    # clock `max_wait` is measured against.
    Outcome = Struct.new(:replaced, :at, :opened_at) do
      # True when this push displaced a still-pending sibling.
      def replaced? = replaced
    end

    class << self
      # @param job [Hash] a normalized job payload
      # @return [String] `debounce:<digest>` for that job's identity
      def key_for(job) = Keys.debounce(Unique.digest_for(job))

      # Collapse `job` into the pending entry for its key, or open a new burst.
      #
      # @param job [Hash] normalized payload; stored minus `at`/`enqueued_at`,
      #   the same bytes {Wurk::Client#push_scheduled} would have written
      # @param wait [Numeric] seconds of quiet before the job fires; every
      #   further enqueue of the same key pushes this out again
      # @param max_wait [Numeric, nil] hard cap measured from the *first*
      #   enqueue of the burst. nil leaves the job able to starve — a key
      #   re-enqueued faster than `wait` never fires — so callers that cannot
      #   rule that out should always set it.
      # @param pool [#with, nil] defaults to this process's pool
      # @return [Outcome]
      def schedule(job, wait:, max_wait: nil, pool: nil)
        seconds = positive_seconds!(wait, 'wait')
        cap = max_wait.nil? ? 0.0 : positive_seconds!(max_wait, 'max_wait')
        reject_shorter_cap!(seconds, cap)

        argv = [seconds, cap, JobUtil.scheduled_member(job), GRACE]
        # Replay-safe: a re-run finds the member it just wrote, ZREMs it and
        # ZADDs it back, so a pool retry after a lost reply converges on one
        # entry rather than a duplicate — the whole point of doing this in a
        # script rather than a pipeline.
        #
        # The replay is not byte-identical: it recomputes `now`, so the fire
        # time moves out by the retry's own latency (and `first` is carried
        # forward, so `max_wait` still caps where it lands). That is the claim
        # worth making anyway. A lost reply means the write probably applied,
        # and refusing the replay only converts a bounded shift into an
        # exception out of `perform_async` for a job that is already scheduled
        # — whose caller then re-enqueues and shifts the fire time regardless.
        raw = with_pool(pool, idempotent: true) do |conn|
          Lua::Loader.eval_cached(conn, :debounce, keys: [key_for(job), Keys::SCHEDULE], argv: argv)
        end
        Outcome.new(raw[0].to_i == 1, raw[1].to_f, raw[2].to_f)
      end

      private

      def positive_seconds!(value, name)
        raise ArgumentError, "debounce #{name} must be a positive number of seconds: #{value.inspect}" \
          unless JobUtil.positive_seconds?(value)

        value.to_f
      end

      # A cap below the quiet period fires every burst at `first + max_wait`
      # regardless of traffic, which is a throttle wearing a debounce's name.
      # Nobody writes that on purpose, so it fails where it was declared.
      def reject_shorter_cap!(wait, cap)
        return if cap.zero? || cap >= wait

        raise ArgumentError, "debounce max_wait (#{cap}) must be at least wait (#{wait})"
      end

      def with_pool(pool, idempotent: false, &)
        pool ? PoolCheckout.with(pool, idempotent, &) : Wurk.redis(idempotent:, &)
      end
    end
  end
end
