# frozen_string_literal: true

require_relative '../keys'
require_relative '../lua'
require_relative '../middleware/poison_pill'
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
      # Unclaimed apply-safety: the move is guarded, but a reply lost after a
      # poison kill would leave the death handlers unfired, and a list holding
      # two identical copies would move the second on a replay. A raise leaves
      # the payload for the next pass instead.
      def call(private_list, public_q, payload)
        job = Middleware::PoisonPill.parse(payload)
        count = @config.redis { |conn| move(conn, private_list, public_q, payload, job) }
        return false unless count

        Metrics::ProcessCounters.increment(:reaper_reclaimed)
        unless count == :uncounted
          Middleware::PoisonPill.recovered!(payload, job, count: count, queue: queue_name(public_q),
                                                          config: @config)
        end
        true
      end

      private

      # Past maxmemory the counter cannot be written, nor the job killed: it goes
      # back uncounted rather than waiting on the memory it would help free.
      def move(conn, private_list, public_q, payload, job)
        keys = [private_list, public_q, Keys::DEAD]
        jid = job && job['jid']
        keys << Middleware::PoisonPill.counter_key(jid) if jid.is_a?(String) && !jid.empty?
        Wurk::Lua::Loader.eval_cached(conn, :reclaim_orphan, keys: keys, argv: [payload, THRESHOLD, TTL, now])
      rescue RedisClient::OutOfMemoryError => e
        :uncounted if OomDrain.requeue(conn, e, private_list, public_q, payload) == 1
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
