# frozen_string_literal: true

require_relative '../lua'
require_relative '../pid_cache'

module Wurk
  class Fetcher
    # The rest of {Fetcher::Reliable#walk}'s non-blocking pass once the first
    # queue came back empty: every remaining queue in one round trip
    # (lib/wurk/lua/fetch_first.lua) instead of one LMOVE per queue. A sparse
    # 100-queue capsule used to pay 100 round trips per pass to reach a job on
    # its last queue; it now pays two. The script walks the order it is given,
    # so strict order, the weighted shuffle and the paused filter all stay
    # Reliable#queues_cmd's.
    #
    # Why not the first queue too, for one round trip: a script pays Redis per
    # key it is handed, before it moves anything — measured on Redis 7.0 at
    # ~13us server time for 10 queues and ~83us for 100, against ~0.2us for a
    # bare LMOVE. A capsule whose first queue is busy is the common shape, and
    # folding that queue into the script made its every fetch 1.4x slower
    # end to end on 10 queues. Leading with the LMOVE keeps that path exactly
    # where it was and spends the script only on a pass that already missed.
    module ManyQueues
      NO_ARGV = [].freeze

      # How long a script pass that found every queue empty answers for the whole
      # fetcher. The script sends two keys per queue, per thread, per poll: 120 KB
      # a pass at 1000 queues, which at concurrency 500 cost a process 70% of a
      # core and Redis 26% of one while idle. A thread skipping it parks in BLMOVE
      # on the first queue for the whole poll, unaware of anything that lands on a
      # later queue meanwhile, so a job can wait out a poll interval (about 2s)
      # with a thread idle. That is the same bound an empty script pass gives it.
      # Not a config knob.
      REST_MISS_BACKOFF = 0.25

      private

      # Queues 2..n. Two queues is one more LMOVE — a one-key script costs more
      # than the move it would wrap.
      #
      # Apply-safe for the reason #lmove is: a claim whose reply was lost left
      # the job in this process's private list, un-ACKed, which the next boot's
      # Reaper reclaims, and the replay claims a different job.
      def claim_rest(queues)
        return lmove(queues[1]) if queues.size == 2

        now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        return nil if now < @rest_empty_until

        keys = claim_keys(queues)
        index, job = config.redis(idempotent: true) do |conn|
          Wurk::Lua::Loader.eval_cached(conn, :fetch_first, keys: keys, argv: NO_ARGV)
        end
        unless job
          @rest_empty_until = now + REST_MISS_BACKOFF
          return nil
        end

        public_q = queues[index]
        priv, name = queue_keys(public_q)
        unit_of_work(public_q, priv, name, job)
      end

      # `[public, private, public, private, ...]` for queues 2..n, fetch_first's
      # KEYS. Strict mode with nothing paused hands #walk the same frozen array
      # every pass, so the steady state reuses one build; a shuffled or filtered
      # list is a fresh array per pass and rebuilds. Keyed on the pid too, for
      # the reason #queue_keys is. Copy-on-write: processor threads share this
      # fetcher.
      def claim_keys(queues)
        pid = PidCache.pid
        cached = @claim_keys
        return cached[2] if cached && cached[0].equal?(queues) && cached[1] == pid

        keys = queues.drop(1).flat_map { |public_q| [public_q, queue_keys(public_q).first] }.freeze
        @claim_keys = [queues, pid, keys].freeze
        keys
      end
    end
  end
end
