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
  #   queue_slot:<queue>   ZSET   member = <identity>:<tid>[:<claim>]
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
  # One member per *claim*. `<identity>:<tid>` is unique across the cluster and
  # stable for one thread, and a processor thread runs one job at a time — but
  # the fetch path's release is deferred, so a claim needs an identity a stale
  # release cannot be mistaken for. {claim_token} appends a per-thread counter
  # for exactly that; a paired acquire/release that never leaves the thread can
  # use {token} itself. Either way a replayed claim finds its own member rather
  # than counting itself twice. Nothing about the job is stored — a slot is
  # capacity, not a claim on a payload, and the payload's own reliability is
  # the private list's job.
  #
  # ## How a hold ends
  #
  # Three ways, in the order they are hoped for:
  #
  #   * The job finishes. `Processor#process`'s `ensure` is the one frame every
  #     exit path passes through, so the release is anchored there — success,
  #     failure, retry, `Handled`, a watchdog timeout, a shutdown raise. The
  #     ZREM rides the ACK's pipeline, so a released slot costs no round trip.
  #   * The holder goes quiet. A quieted process stops fetching, so it stops
  #     taking slots, and the ones it still holds drain with its last jobs — it
  #     never sits on capacity it is not using.
  #   * Nothing at all. A SIGKILLed holder stops refreshing and ages out within
  #     {TTL_SECONDS}. That is the floor the other two are optimizations on top
  #     of, and it is why a live holder has to keep saying so — {HELD} is the
  #     ledger the heartbeat refreshes from (see {refresh_in}).
  #
  # A rolling restart is the one case where a queue can briefly run over its
  # cap: `Swarm::Restart` boots the replacement before it TERMs the old child,
  # so for the length of one drain both generations hold slots. That is
  # deliberate and left alone. Fixing it would mean either starving the
  # replacement until the old child's last job finished — the deploy stalls
  # behind the slowest job on the queue — or handing capacity between processes,
  # which needs the counter this ledger exists to avoid. The excess is bounded
  # by the old child's in-flight count, lasts at most one `drain_timeout`, and
  # is TTL-bounded even if that child is SIGKILLed instead of draining.
  module QueueSlot
    # How long a hold survives with nobody refreshing it. Deliberately the same
    # as `Heartbeat::TTL_SECONDS` (pinned by a test): a hold is refreshed on the
    # beat, so a slot has to outlive a missed beat by exactly as much as the
    # holder's own entry in the `processes` set does. Shorter and a busy
    # process's slots evaporate under a slow Redis while its jobs still run;
    # longer and a killed process's capacity comes back later than the process
    # itself disappears from the dashboard.
    TTL_SECONDS = 60

    # Which slots this process is holding right now, so the heartbeat can
    # extend them on the beat it was already sending.
    #
    # A process-wide singleton rather than fetcher state, for the reason
    # `Processor::WORK_STATE` is one: the reader is the Heartbeat, which lives a
    # layer above the capsules and would otherwise have to walk them looking for
    # fetchers that may not exist. Keyed by holder token, which names one claim
    # ({claim_token}) — a thread runs one job at a time, so the map holds one
    # entry per busy thread and is empty for every install that caps nothing.
    # The exception is the window a failed ACK flush opens: a thread whose
    # finished job's release has not landed yet appears twice until it does,
    # which keeps that hold alive rather than letting it be reused early.
    #
    # Nothing here is authoritative: Redis is. The ledger only decides what gets
    # refreshed, so an entry lost to a crash costs a hold its TTL, never
    # correctness.
    class Held
      def initialize
        @held = {}
        @lock = ::Mutex.new
      end

      def hold(token, slot_key)
        @lock.synchronize { @held[token] = slot_key }
      end

      # Drops the named hold and only the named hold — the slot key is checked
      # as well as the token, so a release that arrives late can never stop the
      # heartbeat refreshing a hold that is actually live.
      def drop(token, slot_key)
        @lock.synchronize { @held.delete(token) if @held[token] == slot_key }
      end

      def snapshot
        @lock.synchronize { @held.dup }
      end

      def size
        @lock.synchronize { @held.size }
      end
    end

    HELD = Held.new

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
      # Paired acquire/release on one thread can use this directly. A *deferred*
      # release cannot; see {claim_token}.
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

      # A holder token naming one *claim*: `<identity>:<tid>:<n>`.
      #
      # The thread half alone would name a holder — a processor thread runs one
      # job at a time — but it does not name a claim, and the fetch path's
      # release is deferred. An ACK whose flush failed is handed back to its
      # thread (`Fetcher::Reliable#restore_pending_acks`), which by then may be
      # running its next job under a fresh hold on the same queue. Both claims
      # would be the same member, so that stale ACK's `ZREM` would take the live
      # job's hold with it and leave the cluster free to admit one over the cap
      # for the rest of that job. With the counter the two are different
      # members, so a stale release names one that is already gone and frees
      # nothing — the same shape as a release arriving after its own hold aged
      # out. It errs the safe way: the finished job's hold lingers until its ACK
      # lands or the TTL takes it, which under-counts rather than over-admits.
      #
      # Built once per claim by the caller and reused across the pool's
      # idempotent retry, so a claim whose reply was lost still replays against
      # its own member and converges on "you hold it" rather than counting
      # itself twice (`fetch_slot.lua`).
      #
      # @return [String]
      def claim_token
        thread = ::Thread.current
        seq = thread.thread_variable_get(:wurk_queue_slot_seq).to_i + 1
        thread.thread_variable_set(:wurk_queue_slot_seq, seq)
        "#{token}:#{seq}"
      end

      # Take one of `queue`'s slots, or report that the cluster is at capacity.
      #
      # Replay-safe, so it runs on the pool's idempotent path: a retried call
      # whose first attempt already landed finds its own member and answers
      # true again rather than reporting a refusal on a slot it holds.
      #
      # Defaults to this thread's {token}, which pairs with a {release} on the
      # same thread. A caller that defers its release past the next claim wants
      # a {claim_token} instead, and has to carry it to the release — the fetch
      # path does, on the unit of work.
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

      # Queue a refresh of every slot this process holds onto a pipeline the
      # caller already owns — the Heartbeat's, so a cap costs no beat traffic of
      # its own: one EVALSHA covering every hold, appended to a write that was
      # going out anyway.
      #
      # Returns without touching the pipeline when nothing is held, which is
      # every process in an install that caps nothing: the whole feature costs
      # such a process one Hash read every 10 seconds.
      #
      # `eval_method` is `Lua::Loader.pipelined_eval`'s — the beat runs through
      # it so a flushed script cache is one replay rather than a lost beat.
      #
      # @return [void]
      def refresh_in(pipe, eval_method = :eval_cached, ttl: TTL_SECONDS)
        held = HELD.snapshot
        return if held.empty?

        keys = []
        argv = [ttl]
        held.each do |holder, slot_key|
          keys << slot_key
          argv << holder
        end
        Lua::Loader.public_send(eval_method, pipe, :refresh_slots, keys: keys, argv: argv)
        nil
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
