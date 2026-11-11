# frozen_string_literal: true

require_relative '../keys'
require_relative '../lua'
require_relative 'poison_pill'
require_relative '../metrics/process_counters'
require_relative 'oom_drain'

module Wurk
  class Fetcher
    # Puts one payload from a private list back where it belongs, for both ways
    # an orphan is found: the Reaper draining a dead owner's list, and
    # SelfReconcile returning a payload its own live process lost track of.
    #
    # The poison-pill verdict is taken in the same script that moves the job
    # (`lua/reclaim_orphan.lua`), so a job past the cap goes straight from the
    # private list to the dead set and is never visible on its public queue. The
    # notifications (death handlers, `super_fetch!`, `on_poison`) follow once
    # the script has returned, for a job no worker can be running.
    class OrphanReclaim
      THRESHOLD = Middleware::PoisonPill::RECOVERY_THRESHOLD
      TTL = Middleware::PoisonPill::RECOVERY_TTL

      def initialize(config)
        @config = config
      end

      # Returns true when this call took the payload off the private list, false
      # when it had already left (another reaper, an ACK).
      #
      # Sent once, never re-sent on a fresh socket: a replay of a script that
      # already ran finds the payload gone and answers "someone else moved it",
      # which skipped the death handlers of a kill (#908), and a list holding two
      # identical copies would move the second. A reply lost after the script ran
      # is settled by reading back what it wrote instead (#settle_lost_reply).
      def call(private_list, public_q, payload)
        job = Middleware::PoisonPill.parse(payload)
        keys = move_keys(private_list, public_q, job)
        count = moved_count(keys, payload, now)
        return false unless count

        Metrics::ProcessCounters.increment(:reaper_reclaimed)
        unless count == :uncounted
          Middleware::PoisonPill.recovered!(payload, job, count: count, queue: queue_name(public_q),
                                                          config: @config)
        end
        true
      end

      private

      def moved_count(keys, payload, score)
        @config.redis { |conn| move(conn, keys, payload, score) }
      rescue RedisClient::ConnectionError => e
        settle_lost_reply(keys, payload, score, e)
      end

      def move_keys(private_list, public_q, job)
        keys = [private_list, public_q, Keys::DEAD]
        jid = job && job['jid']
        keys << Middleware::PoisonPill.counter_key(jid) if jid.is_a?(String) && !jid.empty?
        keys
      end

      # Past maxmemory the counter cannot be written, nor the job killed: it goes
      # back uncounted rather than waiting on the memory it would help free.
      def move(conn, keys, payload, score)
        Wurk::Lua::Loader.eval_once(conn, :reclaim_orphan, keys: keys, argv: [payload, THRESHOLD, TTL, score])
      rescue RedisClient::OutOfMemoryError => e
        :uncounted if OomDrain.requeue(conn, e, keys[0], keys[1], payload) == 1
      end

      # The connection dropped around the script, so it ran or it did not. Only a
      # kill needs settling: the job is gone from the private list, so no later
      # sweep would find it, and the death handlers (a batch's `:death`, a unique
      # lock's release) would never fire. The script wrote the dead-set member
      # at the score this call chose, so that exact score proves the kill was
      # this call's. Returns the recovery count for a kill this call made; nil
      # for a requeue or a move someone else made, which need nothing more;
      # raises the original error when the payload is still in the private list,
      # which is the next pass's to move.
      def settle_lost_reply(keys, payload, score, error)
        private_list, _public_q, dead, counter = keys
        still_there, dead_score, count = @config.redis(idempotent: true) do |conn|
          conn.pipelined do |pipe|
            pipe.call('LPOS', private_list, payload, 'RANK', -1)
            pipe.call('ZSCORE', dead, payload)
            pipe.call('GET', counter) if counter
          end
        end
        # Exact on purpose: the same double, written by the script and read back.
        return count.to_i if dead_score && Float(dead_score) == Float(score) # rubocop:disable Lint/FloatComparison
        raise error if still_there

        nil
      end

      # DeadSet#kill's score format, so the entry sorts with every other kill.
      def now
        ::Process.clock_gettime(::Process::CLOCK_REALTIME).to_s
      end

      def queue_name(public_q)
        public_q.delete_prefix(Keys::QUEUE_PREFIX)
      end
    end
  end
end
