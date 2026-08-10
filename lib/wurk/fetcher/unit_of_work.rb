# frozen_string_literal: true

require_relative '../queue_slot'
require_relative '../middleware/poison_pill'

module Wurk
  class Fetcher
    # `Fetcher::Reliable` reopened, not a second definition: the fetch loop owns
    # which job to claim, and this owns what a claimed job still has to write on
    # its way out — the ACK, the poison-pill counter and the global-concurrency
    # slot. Required from the bottom of `reliable.rb`, once that class exists,
    # the way `lua.rb` requires its loader.
    class Reliable < Fetcher
      # Carries the public queue key, the raw (still-JSON) job payload, the
      # capsule we use to reach Redis, and the fetcher that holds this unit's
      # ACK until it can ride a pipeline. ACK removes from the private list;
      # requeue pushes back to the public queue head so the job is next pulled.
      # LREM count=1 is idempotent for our payloads since each job's JSON
      # contains a unique `jid`.
      #
      # `queue_name` (the queue without its `queue:` prefix) and
      # `private_queue` come off the fetcher's per-queue cache at build time:
      # both are pure functions of the queue this unit came from, so deriving
      # them here would be a per-job cost for a per-queue fact.
      #
      # `jid` is filled in by the Processor once it has parsed the payload —
      # the fetcher never parses. It is only used to retire the job's
      # poison-pill recovery counter, so an ACK without one is still a
      # complete ACK.
      #
      # `slot_key`/`slot_token` name the global-concurrency slot this unit was
      # admitted under, and are set only by Fetcher::Capped — nil is the whole
      # uncapped path, which is why the release below is a field test rather
      # than a question asked of Redis.
      # LREM's count, pre-stringified. Every argument of every command on the
      # ACK pipeline is then a String, which is what keeps it on
      # {Wurk::CommandBuilder}'s allocation-free fast path; an Integer here
      # would send the whole command back through redis-client's normalizer.
      LREM_COUNT = '1'
      private_constant :LREM_COUNT

      UnitOfWork = Struct.new(:queue, :queue_name, :private_queue, :job, :config, :jid, :fetcher,
                              :slot_key, :slot_token, keyword_init: true) do
        # Deferred, never skipped: the LREM goes back to the fetcher, which
        # pipelines it in front of the next fetch's LMOVE instead of spending a
        # round trip of its own. Ordering against the job is unchanged — the
        # LREM still happens only after success or retry handling (Pro §3.2) —
        # so all that moves is the wall clock. Every path that stops fetching
        # flushes first; see #flush_pending_acks.
        def acknowledge
          fetcher.defer_ack(self)
        end

        # Queue this unit's ACK into an already-open pipeline. The counter DEL
        # rides the same round trip rather than taking one of its own: a
        # per-job call would be a fetch+execute regression for the sake of a
        # key that exists for roughly no jobs. See Middleware::PoisonPill.
        #
        # Sending it only for the jobs that own one is not available to us:
        # whether a job was reclaimed lives in the counter, and a reclaimed
        # payload is byte-identical to a first-attempt one (the job JSON is
        # wire-frozen, so the reaper cannot flag it). Reading the counter to
        # decide would spend the very round trip the DEL is riding for free.
        def write_ack(pipe)
          pipe.call('LREM', private_queue, LREM_COUNT, job)
          job_jid = jid.to_s
          Middleware::PoisonPill.clear_in(pipe, job_jid) unless job_jid.empty?
          release_slot_in(pipe) if slot_key
        end

        # Give a global-concurrency slot back inside a pipeline the caller
        # already has open — the ACK's, so a capped job costs no round trip more
        # on the way out than an uncapped one does on the way in. The ZREM lands
        # ahead of the fetch it is pipelined with, so a thread re-competing for
        # the queue it just ran releases before it asks, never after.
        #
        # Idempotent by construction (QueueSlot#release): it names one member,
        # so a replayed ACK frees nothing that has since been handed on. The
        # member names this *claim* rather than this thread, which is what makes
        # that true of a stale ACK too — one handed back by a failed flush
        # (Fetcher::Reliable#restore_pending_acks) after the thread has already
        # claimed its next slot on the same queue. See QueueSlot.claim_token.
        def release_slot_in(pipe)
          QueueSlot::HELD.drop(slot_token, slot_key)
          pipe.call('ZREM', slot_key, slot_token)
        end

        # The same release for the one path that deliberately does not ACK:
        # Wurk::Shutdown, where the payload stays in the private list to be
        # requeued and re-run somewhere else. Whoever re-runs it needs the
        # capacity, so this cannot wait out the TTL — and there is no ACK left
        # to ride, hence the round trip. Bounded to the jobs a hard shutdown
        # kills mid-flight.
        def release_slot
          return unless slot_key

          QueueSlot::HELD.drop(slot_token, slot_key)
          config.redis(idempotent: true) { |conn| conn.call('ZREM', slot_key, slot_token) }
        end

        def requeue
          config.redis { |conn| conn.call('RPUSH', queue, job) }
        end
      end
    end
  end
end
