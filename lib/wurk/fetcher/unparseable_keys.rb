# frozen_string_literal: true

require_relative '../keys'

module Wurk
  class Fetcher
    # The Reaper's report on a `queue:*|*` key that is not a private list it
    # can read the owner of — a list whose owner tail does not parse, say
    # `queue:<queue>|<host>|not-a-pid|<index>`, left behind by a producer that
    # is not Wurk. Sidekiq Pro's four-part shape
    # (`queue:<queue>|<host>|<pid>|<index>`) parses as the pre-nonce tail and
    # is reclaimed, so Pro's lists are not reported. Nothing will ever reclaim
    # the jobs of an unparseable list, so it is said once per key per process
    # (WARN, with the list's length) rather than skipped in silence on every
    # sweep.
    #
    # The dedup memory is an in-memory ::Set in THIS process only: one
    # UnparseableKeys per Reaper, one Reaper per Launcher, one Launcher per
    # worker process, all of them built after the fork. Nothing about it
    # reaches Redis — no key, no TTL, nothing shared — so there is no
    # fleet-wide suppression: every worker that sweeps the key logs it for
    # itself, and a restart starts with an empty set and reports it again.
    #
    # A public queue whose own name contains `|` matches the same SCAN pattern,
    # so a key whose name is in the `queues` SET is not reported.
    class UnparseableKeys
      # Distinct keys remembered as already reported. Bounded so a keyspace
      # full of odd keys cannot grow it without limit; past the bound the
      # memory is cleared and keys are reported again.
      MEMORY = 1000

      def initialize(config)
        @config = config
        @reported = ::Set.new
      end

      def report(key)
        return if @reported.include?(key)

        public_queue, size = inspect_key(key)
        return if public_queue

        @reported.clear if @reported.size >= MEMORY
        @reported << key
        @config.logger.warn do
          "reaper: #{key.inspect} looks like a reliable-fetch private list but does not match " \
            "queue:<queue>|<host>|<pid>|<nonce>|<index>; its #{size} job(s) will not be recovered " \
            'automatically. Inspect it and LMOVE them back onto their queue by hand ' \
            'if they belong to a dead process. ' \
            'Reported once per process: every worker that sees the key logs it for itself, ' \
            'and it is reported again after a restart.'
        end
      rescue StandardError => e
        @config.handle_exception(e, context: 'wurk-reaper')
      end

      private

      def inspect_key(key)
        member, size = @config.redis(idempotent: true) do |conn|
          conn.pipelined do |pipe|
            pipe.call('SISMEMBER', Keys::QUEUES_SET, key.delete_prefix(Keys::QUEUE_PREFIX))
            pipe.call('LLEN', key)
          end
        end
        [member == 1, size]
      end
    end
  end
end
