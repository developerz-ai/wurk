# frozen_string_literal: true

require_relative 'job_util'
require_relative 'keys'
require_relative 'lua'
require_relative 'pool_checkout'
require_relative 'unique'

module Wurk
  # Throttle-to-slot — at most one job per identity per fixed slot of
  # wall-clock time; every extra that arrives inside the slot is dropped. A
  # Wurk extra, not a Sidekiq surface, and the third distinct answer to "this
  # was enqueued more often than it needs to run":
  #
  #   Wurk::Unique    rejects the duplicate, keeps the first, until its lock clears
  #   Wurk::Debounce  replaces the pending job, keeps the last, fires after quiet
  #   Wurk::Throttle  drops the extra, keeps the first, once per slot
  #
  # The use is a ceiling rather than a collapse: poll an API at most once a
  # minute however many events ask for it, send one digest email per hour per
  # user, rebuild a leaderboard on a fixed cadence no matter the write rate.
  #
  # Redis schema — one key per identity per slot, holding the winner:
  #
  #   throttle:<digest>:<slot index>   STRING   the jid that won the slot
  #
  # Slots are aligned to the Unix epoch, not to first use: with `slot: 60` the
  # boundaries are the calendar minutes, and every producer means the same
  # minute by "this slot". That is pg-boss's `singletonSeconds`, which derives
  # `singleton_on` as floor(epoch(now) / singletonSeconds), and it is what
  # separates a slot from a cooldown. A cooldown measured from first use is a
  # rolling one-per-N rate limit — {Wurk::Limiter}'s window type already is
  # one, sliding from first use by design, so this is not a second copy of it.
  #
  # Nothing is stored but the winner's jid. An admitted job is enqueued by the
  # caller exactly as it would have been with no policy at all, so it is an
  # ordinary queue entry that {Wurk::Queue}, the dashboard and a stock Sidekiq
  # process read unchanged.
  #
  # Identity is {Wurk::Unique}'s digest of `[class, queue, args]`, so a class
  # that narrows its key with `sidekiq_unique_context` narrows its throttle key
  # the same way — one documented hook covers all three policies rather than
  # each growing its own.
  #
  # ## What a dropped enqueue returns
  #
  # Two layers, two answers, deliberately.
  #
  # {.admit} hands back an {Outcome} naming the jid that owns the slot: the
  # caller's own when it won, the incumbent's when it lost. The incumbent is
  # the one fact a loser cannot recover for itself afterwards — by the time it
  # asks, the slot may have closed, and asking costs a second round trip that
  # races the boundary. It is also exactly what a "dropped, blocked by jid=..."
  # log line needs, the line {Wurk::Unique::ClientMiddleware} already writes.
  #
  # The enqueue door built on top of this returns **nil**, not the winner's
  # jid. `perform_async` returning a jid means "that jid is now in Redis, go
  # poll it, cancel it, hang a batch off it", and the winner's jid is not the
  # loser's to do any of that with — handing it over invites a caller to wait
  # on someone else's job and to cancel work it does not own. nil is what
  # pg-boss's `send` resolves on a slot collision ("the second request will
  # resolve a null instead of a job id"), and what {Wurk::Unique} already
  # returns when it drops a duplicate, so all three doors agree.
  #
  # ## Dropped, not deferred
  #
  # An extra is dropped, never rolled into the next slot. pg-boss offers that
  # as `singletonNextSlot` and builds `sendDebounced` out of it, but {Wurk::Debounce}
  # already covers "collapse the burst and fire it later" and covers it better:
  # it keeps the *last* payload, where a next-slot deferral keeps whichever
  # extra happened to arrive first and discards every edit after it. Two
  # policies that both defer would only differ in which stale payload they run.
  module Throttle
    # What one throttled enqueue did to its slot.
    #
    # `jid` is whoever owns the slot — the caller when `admitted?`, the
    # incumbent when not — and is always set, because a job without one is
    # refused before the script runs. `slot_ends_at` is the epoch second it closes,
    # so it is the earliest this identity can be admitted again; it comes back
    # from the script because deriving it here would mean re-aligning against
    # the caller's clock instead of the one the decision was made on.
    Outcome = Struct.new(:admitted, :jid, :slot_ends_at) do
      # True when this push claimed the slot and the caller should enqueue.
      def admitted? = admitted

      # True when another job already held the slot and this push is dropped.
      def dropped? = !admitted
    end

    class << self
      # @param job [Hash] a normalized job payload
      # @return [String] `throttle:<digest>` — the identity prefix the live
      #   slot keys hang off, not a key in its own right
      def key_prefix_for(job) = Keys.throttle(Unique.digest_for(job))

      # Claim this job's slot, or report who already holds it.
      #
      # @param job [Hash] normalized payload; only its identity and `jid` are
      #   read — the payload itself is never stored
      # @param slot [Numeric] slot width in whole seconds
      # @param pool [#with, nil] defaults to this process's pool
      # @return [Outcome]
      def admit(job, slot:, pool: nil)
        seconds = whole_seconds!(slot)
        jid = jid!(job)

        # Replay-safe: a re-run after a lost reply finds its own jid in the
        # slot and is admitted again, so a pool retry converges on "won"
        # instead of reporting a drop the caller never suffered.
        raw = with_pool(pool, idempotent: true) do |conn|
          Lua::Loader.eval_cached(conn, :throttle_slot, keys: [key_prefix_for(job)], argv: [seconds, jid])
        end
        Outcome.new(raw[0].to_i == 1, raw[1], raw[2].to_f)
      end

      private

      # Whole seconds, because a slot boundary is a wall-clock landmark every
      # producer has to land on identically and `EX` cannot express a fraction
      # of one. ActiveSupport durations pass: `5.minutes` is a Numeric worth 300.
      def whole_seconds!(value)
        return value.to_i if JobUtil.positive_seconds?(value) && (value.to_f % 1).zero?

        raise ArgumentError, "throttle slot must be a positive whole number of seconds: #{value.inspect}"
      end

      # The slot stores the jid and hands it back as the answer to "who won",
      # so a payload without one turns every later drop into an unattributable
      # one. Refused here rather than left to render as an empty holder.
      def jid!(job)
        jid = job['jid'].to_s
        raise ArgumentError, "throttled job must carry a jid: #{job.inspect}" if jid.empty?

        jid
      end

      def with_pool(pool, idempotent: false, &)
        pool ? PoolCheckout.with(pool, idempotent, &) : Wurk.redis(idempotent:, &)
      end
    end
  end
end
