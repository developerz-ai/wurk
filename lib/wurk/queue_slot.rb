# frozen_string_literal: true

require_relative 'component'
require_relative 'keys'
require_relative 'lua'
require_relative 'pool_checkout'

module Wurk
  # Global per-queue concurrency — "at most N jobs from this queue running
  # across the whole cluster, whatever the worker count". A Wurk extra, not a
  # Sidekiq surface: Oban Pro's Smart Engine and BullMQ both sell this, and
  # Sidekiq has no equivalent.
  #
  # This module is the slot model on its own — the ledger of who is running
  # what, and nothing about when it is consulted. Fetching under a cap is the
  # fetcher's job.
  #
  # ## Why it is not a counter
  #
  # A counter is the obvious implementation and the wrong one. `INCR` on fetch
  # and `DECR` on completion is correct exactly until a holder is SIGKILLed
  # between the two, and then the count never comes back down: the queue runs
  # one job short for the rest of the cluster's life, with no way to tell a
  # leaked unit from a busy one. Bolting a TTL onto the counter trades that for
  # the mirror bug — the whole count expires at once while jobs are still
  # running, and the cap briefly stops existing.
  #
  # So the ledger holds the *holders*, one ZSET member each:
  #
  #   queue_slot:<queue>   ZSET   member = <identity>:<tid>
  #                               score  = epoch the hold expires unless
  #                                        its holder refreshes it
  #
  # Both failure modes then answer themselves. A killed holder stops refreshing
  # and its member ages out, so capacity returns within {TTL_SECONDS} with no
  # operator action. A release names one member, so a release arriving after
  # its own hold already expired removes nothing instead of freeing a slot that
  # has since been handed to someone else.
  #
  # ## What a hold is
  #
  # One member per *thread*, because a processor thread runs one job at a time:
  # `<identity>:<tid>` is unique across the cluster and stable for that thread,
  # which is also what makes a replayed acquire converge (it finds its own
  # member rather than counting itself twice). Nothing about the job is stored
  # — a slot is capacity, not a claim on a payload, and the payload's own
  # reliability is the private list's job.
  module QueueSlot
    # How long a hold survives with nobody refreshing it. Deliberately the same
    # as `Heartbeat::TTL_SECONDS` (pinned by a test): a hold is refreshed on the
    # beat, so a slot has to outlive a missed beat by exactly as much as the
    # holder's own entry in the `processes` set does. Shorter and a busy
    # process's slots evaporate under a slow Redis while its jobs still run;
    # longer and a killed process's capacity comes back later than the process
    # itself disappears from the dashboard.
    TTL_SECONDS = 60

    class << self
      # @param queue [String] unprefixed queue name
      # @return [String] `queue_slot:<queue>`
      def key_for(queue) = Keys.queue_slot(queue)

      # This thread's holder token, `<identity>:<tid>`.
      #
      # Memoized per thread, keyed on the pid: building it costs a
      # `gethostname` syscall, and every acquire and release on this thread
      # wants the same string. The pid guard is `Component.tid`'s — a thread
      # that forked keeps its thread-locals in the child, where both the pid
      # and the tid have moved, and a child reusing the parent's token would
      # share the parent's slot instead of taking one of its own.
      #
      # @return [String]
      def token
        thread = ::Thread.current
        pid = ::Process.pid
        memo = thread.thread_variable_get(:wurk_queue_slot_token)
        return memo[1] if memo && memo[0] == pid

        built = "#{Component.identity}:#{Component.tid}".freeze
        thread.thread_variable_set(:wurk_queue_slot_token, [pid, built].freeze)
        built
      end

      # Take one of `queue`'s slots, or report that the cluster is at capacity.
      #
      # Replay-safe, so it runs on the pool's idempotent path: a retried call
      # whose first attempt already landed finds its own member and answers
      # true again rather than reporting a refusal on a slot it holds.
      #
      # @param queue [String] unprefixed queue name
      # @param capacity [Integer] cluster-wide ceiling for this queue
      # @param ttl [Integer] seconds the hold survives unrefreshed
      # @param token [String] holder, defaults to this thread's
      # @param pool [#with, nil] defaults to this process's pool
      # @return [Boolean] true when the caller now holds a slot
      def acquire(queue, capacity:, ttl: TTL_SECONDS, token: self.token, pool: nil) # rubocop:disable Naming/PredicateMethod
        limit = positive_integer!(:capacity, capacity)
        seconds = positive_integer!(:ttl, ttl)

        with_pool(pool, idempotent: true) do |conn|
          Lua::Loader.eval_cached(conn, :queue_slot, keys: [key_for(queue)], argv: [limit, token, seconds])
        end == 1
      end

      # Give back a slot. A bare ZREM rather than a script so it can ride a
      # pipeline the caller already has open — the release belongs with the
      # job's ACK, not in a round trip of its own.
      #
      # Idempotent by construction: it can only ever remove this holder's own
      # member, so releasing twice, or releasing a hold that already expired,
      # frees nothing that belongs to anyone else.
      #
      # @return [Boolean] true when the caller's hold was still live
      def release(queue, token: self.token, pool: nil) # rubocop:disable Naming/PredicateMethod
        with_pool(pool, idempotent: true) { |conn| conn.call('ZREM', key_for(queue), token) } == 1
      end

      # How many of `queue`'s slots are held right now.
      #
      # Counts live holds only, so a killed holder's slot stops being reported
      # the moment it expires rather than when the next acquire sweeps it. The
      # cutoff is the reader's clock (a plain ZCOUNT cannot ask for Redis's),
      # which is a gauge for humans and for tests — admission never reads this,
      # it counts under the script's own clock.
      #
      # @return [Integer]
      def in_use(queue, pool: nil)
        cutoff = format('(%.6f', ::Time.now.to_f)
        with_pool(pool, idempotent: true) { |conn| conn.call('ZCOUNT', key_for(queue), cutoff, '+inf') }
      end

      private

      # Refused here rather than passed to the script: a capacity that coerced
      # to 0 is a queue nothing may ever run, and a ttl that coerced to 0 is a
      # hold that expires before it is written. Both fail as silence.
      def positive_integer!(name, value)
        number = Integer(value, exception: false)
        raise ArgumentError, "#{name} must be a positive Integer, got #{value.inspect}" unless number&.positive?

        number
      end

      def with_pool(pool, idempotent: false, &)
        pool ? PoolCheckout.with(pool, idempotent, &) : Wurk.redis(idempotent:, &)
      end
    end
  end
end
