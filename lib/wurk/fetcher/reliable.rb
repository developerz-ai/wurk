# frozen_string_literal: true

require 'socket'
require_relative '../component'
require_relative '../keys'
require_relative '../lua'
require_relative '../fetcher'

module Wurk
  class Fetcher
    # Default fetcher. Each public queue is paired with a per-process
    # private list (`queue:<name>|<host>|<pid>|<idx>`); a job is moved
    # atomically from the public tail to the private head via LMOVE, and
    # stays there until the Processor explicitly ACKs (LREM). SIGKILL
    # between fetch and ack leaves the job in the private list, where the
    # next boot of this process reclaims it via bulk_requeue.
    #
    # Priority handling: iterate queues_cmd in order with non-blocking
    # LMOVE, then fall back to a blocking BLMOVE on the first queue so an
    # empty poll doesn't spin Redis. BLMOVE has no multi-key form, so
    # blocking on a single queue is the best Redis gives us. The block
    # timeout defaults to TIMEOUT (2s) and is overridable per the Pro
    # super_fetch §3.3 `config.fetch_poll_interval` knob.
    #
    # Spec: docs/target/sidekiq-pro.md §3 (super_fetch, §3.3 poll interval),
    # docs/target/sidekiq-free.md §15 (TIMEOUT=2).
    class Reliable < Fetcher
      include Component

      # Default BLMOVE block timeout; overridable via config.fetch_poll_interval.
      TIMEOUT = 2

      # Carries the public queue key, the raw (still-JSON) job payload,
      # and the capsule we use to reach Redis. ACK removes from the private
      # list; requeue pushes back to the public queue head so the job is
      # next pulled. LREM count=1 is idempotent for our payloads since
      # each job's JSON contains a unique `jid`.
      UnitOfWork = Struct.new(:queue, :job, :config, keyword_init: true) do
        def acknowledge
          config.redis do |conn|
            conn.call('LREM', Reliable.private_queue_name(queue), 1, job)
          end
        end

        def queue_name
          queue.delete_prefix(Keys::QUEUE_PREFIX)
        end

        def requeue
          config.redis { |conn| conn.call('RPUSH', queue, job) }
        end
      end

      # Class-level so UnitOfWork can compute the private list without
      # carrying a back-reference to its parent fetcher. Index defaults to
      # 0 — we run one fetcher per capsule today. Multi-processor topology
      # (one private list per processor slot) is a future Manager concern.
      def self.private_queue_name(public_queue, index = 0)
        host = ENV['DYNO'] || Socket.gethostname
        "#{public_queue}|#{host}|#{::Process.pid}|#{index}"
      end

      def initialize(capsule)
        super()
        @config = capsule
        @done = false
      end

      def retrieve_work
        return nil if @done

        queues = queues_cmd
        return nil if queues.empty?

        queues.each do |public_q|
          uow = lmove(public_q)
          return uow if uow
        end
        blmove(queues.first)
      end

      # Called on shutdown for jobs the Processor couldn't finish in time.
      # Atomically moves each still-private UoW back to its public queue via
      # the RELIABLE_REQUEUE Lua (LREM-guarded RPUSH): the job leaves the
      # per-process private list and reappears on the public queue in one hop,
      # so it's visible immediately after a deploy instead of waiting for the
      # next boot's reaper. The guard makes the move idempotent against the
      # cross-thread `job`-read race in Manager#hard_shutdown — a Processor
      # that ACKed in that window is a no-op (LREM misses, RPUSH skipped), so a
      # finished job is never resurrected. Sidekiq Pro super_fetch §3 retains
      # in-flight in the private list until the next boot; we prefer the
      # immediate move so a rolling deploy recovers work without a restart.
      def bulk_requeue(in_progress)
        return if in_progress.nil? || in_progress.empty?

        config.redis { |conn| requeue_pipelined(conn, in_progress) }
      end

      # Prefixed queue keys (`queue:<name>`) in fetch order. Strict mode
      # preserves declaration order. Random/weighted shuffle each call —
      # `@queues` is pre-expanded by weight in Capsule#queues=, so uniform
      # shuffle yields weighted fairness; .uniq trims duplicates. Paused
      # queues are filtered after shuffle so the membership test runs on
      # the smallest possible set.
      def queues_cmd
        names = config.mode == :strict ? config.queues : config.queues.shuffle.uniq
        paused = paused_names
        names = names.reject { |q| paused.include?(q) } unless paused.empty?
        names.map { |q| "#{Keys::QUEUE_PREFIX}#{q}" }
      end

      # Quiet hook (Manager#quiet). Flips the drain flag so retrieve_work
      # short-circuits: once quieted, no processor can pull a fresh UoW, even
      # one sitting in the between-jobs window (Processor#run only re-checks its
      # own @done between iterations). Quiet is one-way — matches Sidekiq TSTP
      # (spec §21.3), there is no un-terminate.
      def terminate
        @done = true
      end

      private

      # One pipelined RELIABLE_REQUEUE EVALSHA per UoW. Mirrors
      # Client#push_batched_pipelined: a pipelined EVALSHA surfaces NOSCRIPT
      # only at finalize (never to eval_cached's inline rescue). Every command
      # here is the same script, so a flushed cache fails all of them and
      # applies none — recover by reloading once and replaying the whole
      # pipeline via source-embedded EVAL.
      def requeue_pipelined(conn, in_progress, eval_method: :eval_cached)
        conn.pipelined do |pipe|
          in_progress.each do |uow|
            Wurk::Lua::Loader.public_send(
              eval_method, pipe, :reliable_requeue,
              keys: [self.class.private_queue_name(uow.queue), uow.queue],
              argv: [uow.job]
            )
          end
        end
      rescue RedisClient::CommandError => e
        raise unless e.message.to_s.start_with?('NOSCRIPT')

        Wurk::Lua::Loader.script_load_all(conn)
        requeue_pipelined(conn, in_progress, eval_method: :eval_with_source)
      end

      # SMEMBERS of the `paused` SET. One round-trip per fetch pass; the
      # set is tiny in practice (one entry per paused queue) so the cost
      # is dominated by the BLMOVE that follows. Returns a Set for O(1)
      # lookup against the (often weighted-expanded) queue list.
      def paused_names
        config.redis { |conn| conn.call('SMEMBERS', Keys::PAUSED_SET) }.to_set
      end

      def lmove(public_q)
        priv = self.class.private_queue_name(public_q)
        job = config.redis { |conn| conn.call('LMOVE', public_q, priv, 'RIGHT', 'LEFT') }
        job ? UnitOfWork.new(queue: public_q, job: job, config: config) : nil
      end

      def blmove(public_q)
        priv = self.class.private_queue_name(public_q)
        timeout = poll_interval
        # Dedicated fetch pool, not the main one: a parked BLMOVE holds its slot
        # for the whole block window, so routing it here keeps idle fetchers from
        # starving the main pool's background loops (#101). Extend the socket
        # read-timeout one second past BLMOVE's own server-side timeout so the
        # connection's read timeout can't fire while BLMOVE is legitimately blocked.
        job = config.fetch_redis do |conn|
          conn.blocking_call(timeout + 1, 'BLMOVE', public_q, priv, 'RIGHT', 'LEFT', timeout)
        end
        job ? UnitOfWork.new(queue: public_q, job: job, config: config) : nil
      end

      # BLMOVE block timeout for an empty poll. `config.fetch_poll_interval`
      # (Pro super_fetch §3.3) overrides the TIMEOUT default; nil → TIMEOUT.
      def poll_interval
        config.fetch_poll_interval || TIMEOUT
      end
    end
  end
end
