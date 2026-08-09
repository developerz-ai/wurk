# frozen_string_literal: true

require_relative '../keys'
require_relative '../lua'
require_relative '../queue_slot'

module Wurk
  class Fetcher
    # Everything the reliable fetcher does differently when one of its queues
    # carries a global concurrency cap (`config.global_concurrency`).
    #
    # Prepended onto {Fetcher::Reliable}, so the separation is structural rather
    # than a claim in a comment: an install that caps nothing resolves one
    # boolean at boot and every fetch pass hands straight back to `super` — the
    # unchanged loop — without touching another line in this file. The cost of
    # the whole feature to everyone else is that one test and the frame it sits
    # in, which is why `rake bench` unconfigured and `bench/command_count.rb` are
    # the gate on this slice rather than an argument about it.
    #
    # The cap itself — the ledger of who is running what — is {Wurk::QueueSlot}
    # and `lib/wurk/lua/queue_slot.lua`. This is only about *fetching* under one:
    # asking the question in the same round trip that claims the job, and
    # deciding what a worker does with a queue that says no.
    module Capped
      # How long a queue that answered "the cluster is at capacity" is skipped
      # locally before this fetcher asks again.
      #
      # Without it a capped queue sitting at capacity costs a round trip per
      # processor thread per pass, forever — the fetcher spins on a `no` that
      # cannot change faster than a job finishes somewhere in the cluster. With
      # it the cost is bounded at four questions a second per capped queue for
      # the whole capsule, and the price is that capacity freed on another host
      # is picked up up to a quarter second late. Much shorter and the round
      # trips come back; much longer and a cap starts to behave like a throttle.
      # Not a config knob — a cap is a ceiling on how much runs, never a promise
      # about latency.
      CAPPED_BACKOFF = 0.25

      # The two of fetch_slot.lua's three answers a caller acts on. Its third,
      # `1`, means the queue was empty — which costs and means exactly what an
      # empty uncapped queue does, so nothing compares against it.
      AT_CAPACITY = 0
      CLAIMED = 2

      # One capped queue's ceiling, its slot key, and the local clock that keeps
      # a queue at capacity from costing a round trip per pass. Built once per
      # capped queue at boot: the fetch path never reads a config Hash, and a cap
      # cannot change under a running fetcher anyway (`global_concurrency=`
      # refuses to run once the configuration is frozen).
      #
      # One per queue per fetcher, so a capsule's processor threads share it: a
      # refusal is a statement about the cluster, not about the thread that heard
      # it, and suppressing the retry for all of them is the whole saving. They
      # race on `blocked_until` — the loser writes an equally fresh deadline, and
      # the worst a torn read can cost is one extra round trip. A gate inherited
      # across a fork can carry a stale deadline for the same reason it is
      # harmless: at worst the child's first pass on that queue waits out a
      # backoff it did not earn.
      Gate = Struct.new(:capacity, :slot_key, :blocked_until) do
        def blocked?(now) = now < blocked_until

        def block!(now)
          self.blocked_until = now + CAPPED_BACKOFF
        end
      end

      # Resolved here and never again. The fetch path must not read a config
      # Hash per pass to discover that this install caps nothing, so the answer
      # is a boolean and a Hash of prebuilt gates, both settled while the
      # capsule is materializing its fetcher (`Capsule#prepare!`).
      def initialize(capsule)
        super
        @gates = capsule.config.global_concurrency.to_h do |name, capacity|
          [name, Gate.new(capacity, Keys.queue_slot(name).freeze, 0.0)]
        end.freeze
        @capped = !@gates.empty?
      end

      private

      # #walk for a capsule that caps at least one of its queues; every other
      # install falls straight through to the loop this decorates.
      #
      # A capped queue at capacity is skipped *locally* — no round trip, and the
      # pass carries on to the queues behind it. That is the fairness
      # requirement: one full queue must never stop this worker serving the
      # others, and must not be able to spin the fetcher either. Skipping is also
      # what keeps the held ACK, which is only ever handed to a queue we are
      # about to talk to.
      def walk(queues)
        return super unless @capped

        ack = take_pending_ack
        now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        queues.each do |public_q|
          # `[private list, unprefixed name]`, the tuple #queue_keys caches; the
          # name is what a cap is declared against.
          keys = queue_keys(public_q)
          gate = @gates[keys[1]]
          next if gate&.blocked?(now)

          uow = gate ? claim(public_q, keys, gate, ack, now) : lmove(public_q, ack)
          ack = nil
          return uow if uow
        end
        wait_capped(queues, ack)
      end

      # The gated twin of #lmove: fetch_slot.lua answers the cap and performs the
      # LMOVE in one call, so a capped queue costs the same single round trip an
      # uncapped one does and the held ACK still rides in front of it. Bracketing
      # the existing fetch with a separate acquire and release instead measured
      # 2.2x-2.6x the uncapped cost (the slice's measurement doc); that shape is
      # what this method exists to avoid.
      #
      # Claims the same apply-safety #lmove does, for the same reason: a claim
      # whose reply was lost leaves the job in *this* process's private list
      # un-ACKed, which the next boot's Reaper already reclaims, and the script's
      # own replay arm refreshes this token's hold rather than counting it twice.
      def claim(public_q, keys, gate, ack, now)
        priv, name = keys
        token = QueueSlot.token
        script_keys = [gate.slot_key, public_q, priv]
        status, payload = config.redis(idempotent: true) do |conn|
          fetch_slot(conn, script_keys, gate.capacity, token, ack)
        end
        return hold(unit_of_work(public_q, priv, name, payload), gate.slot_key, token) if status == CLAIMED

        # The refusal is the only answer worth remembering: it cannot change
        # faster than a job finishes somewhere in the cluster, so re-asking on
        # every pass is how a full queue turns into a spin. An empty queue is
        # remembered by nobody, exactly as on the uncapped path.
        gate.block!(now) if status == AT_CAPACITY
        nil
      rescue StandardError
        # The window #lmove guards: the ACK left its slot but never reached
        # Redis, so hand it back or a finished job runs a second time.
        defer_ack(ack) if ack
        raise
      end

      # The claim's other half — the bookkeeping the script's ZADD implies.
      #
      # The unit carries the slot it was admitted under so its release can name
      # that slot without re-deriving anything on the way out
      # (UnitOfWork#write_ack), and the process ledger carries it so the
      # heartbeat keeps the hold alive under a job that outlives the TTL.
      def hold(uow, slot_key, token)
        QueueSlot::HELD.hold(token, slot_key)
        uow.slot_key = slot_key
        uow.slot_token = token
        uow
      end

      # One EVALSHA, or that same EVALSHA behind the held ACK in one pipeline —
      # the shape #lmove already uses, so the gate costs no round trip of its
      # own either way.
      def fetch_slot(conn, keys, capacity, token, ack)
        argv = [capacity, token, QueueSlot::TTL_SECONDS]
        return Wurk::Lua::Loader.eval_cached(conn, :fetch_slot, keys: keys, argv: argv) unless ack

        Wurk::Lua::Loader.pipelined_eval(conn) do |pipe, eval_method|
          ack.write_ack(pipe)
          Wurk::Lua::Loader.public_send(eval_method, pipe, :fetch_slot, keys: keys, argv: argv)
        end.last
      end

      # #walk's blocking fall-through, for a capsule that caps a queue. BLMOVE
      # has no gated form — a script cannot block — so a capped queue is never
      # the one we park on: the block goes to the first *uncapped* queue in fetch
      # order, and when every fetchable queue is capped there is nothing to park
      # on at all, so we idle the wall clock a timed-out block would have spent.
      # Sidekiq's BasicFetch idles on the same terms.
      #
      # While a capped queue is sitting at capacity the block is shortened to the
      # gate's own re-check, so capacity freed on another host is picked up in a
      # backoff instead of a poll interval. An idle capsule keeps today's
      # cadence: nothing is blocked, so nothing is shortened.
      def wait_capped(queues, ack)
        # A pass that skipped every capped queue never handed its ACK to
        # anything. A blocking call cannot carry one, so give it back rather than
        # drop it — an LREM that is never sent leaves a finished job in the
        # private list for the next boot's reaper to run again.
        defer_ack(ack) if ack
        wait = capped_wait(queues)
        open_q = queues.find { |public_q| gate_for(public_q).nil? }
        return blmove(open_q, wait) if open_q

        # Which also hands back the slot this thread's last job ran under: a
        # held ACK carries that ZREM, and a thread idling out a backoff with no
        # job in hand must not keep capacity somebody else could be using. The
        # two cases are the same one — an ACK survives the loop above only when
        # every queue was gate-blocked, and a gate-blocked queue is a capped
        # queue, so there was never an uncapped one to park on either.
        flush_pending_acks
        sleep wait
        nil
      end

      def capped_wait(queues)
        now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        blocked = queues.any? { |public_q| gate_for(public_q)&.blocked?(now) }
        blocked ? [poll_interval, CAPPED_BACKOFF].min : poll_interval
      end

      def gate_for(public_q)
        @gates[queue_keys(public_q)[1]]
      end
    end
  end
end
