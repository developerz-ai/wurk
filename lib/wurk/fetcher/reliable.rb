# frozen_string_literal: true

require 'socket'
require_relative '../component'
require_relative '../keys'
require_relative '../lua'
require_relative '../fetcher'
require_relative '../middleware/poison_pill'

module Wurk
  class Fetcher
    # Default fetcher. Each public queue is paired with a per-process
    # private list (`queue:<name>|<host>|<pid>|<nonce>|<idx>`); a job is moved
    # atomically from the public tail to the private head via LMOVE, and
    # stays there until the Processor explicitly ACKs (LREM). SIGKILL
    # between fetch and ack leaves the job in the private list, where the
    # next boot of this process reclaims it via bulk_requeue.
    #
    # The ACK does not take a round trip of its own: it is held here and
    # pipelined in front of the next fetch's LMOVE, so a worker draining a busy
    # queue costs one round trip per job in total. See #flush_pending_acks for
    # the paths that must send a held ACK before they stop fetching, and
    # docs/idea/parity-divergences.md for the window that widens.
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

      # How long a fetcher may answer from its own copy of the `paused` SET
      # before re-reading it. Deliberately equal to the default poll interval:
      # a worker parked in BLMOVE already cannot observe a pause until that
      # block returns, so caching the busy path for the same window leaves the
      # fleet's worst-case pause latency where it was. A constant, never a
      # config knob — see
      # docs/plans/2026/08/06/101-faster-than-sidekiq/00-semantics-signoff.md.
      PAUSED_TTL = 2

      # Backoff for the quieted short-circuit. Manager#quiet terminates the
      # shared fetcher before it terminates the processors, and Processor#run
      # loops on its *own* flag — so in that window every processor would spin
      # on an instant nil. Kept below Manager::PAUSE_TIME, which #stop sleeps
      # immediately after #quiet, so this pause adds no drain latency.
      QUIET_PAUSE = 0.05

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
      UnitOfWork = Struct.new(:queue, :queue_name, :private_queue, :job, :config, :jid, :fetcher,
                              keyword_init: true) do
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
          pipe.call('LREM', private_queue, 1, job)
          job_jid = jid.to_s
          Middleware::PoisonPill.clear_in(pipe, job_jid) unless job_jid.empty?
        end

        def requeue
          config.redis { |conn| conn.call('RPUSH', queue, job) }
        end
      end

      # Class-level: the name is a pure function of the public queue and this
      # process's identity, and both the fetcher and the Reaper need it (the
      # fetcher's units carry the string #queue_keys built for them, so nothing
      # on the hot path calls this per job). Index defaults to 0 — we run one
      # fetcher per capsule today.
      # Multi-processor topology (one private list per processor slot) is a
      # future Manager concern.
      #
      # The nonce marks the incarnation. host+pid alone is ambiguous once PID
      # namespaces are in play: a restarted container reuses both, so the
      # reaper's `kill(0)` liveness check would read a dead owner's list as
      # live (jobs stranded) or a live owner's as dead (job run twice). Keys
      # written before the nonce existed stay reclaimable — Reaper#parse_owner
      # accepts both shapes.
      def self.private_queue_name(public_queue, index = 0)
        host = ENV['DYNO'] || Socket.gethostname
        "#{public_queue}|#{host}|#{::Process.pid}|#{Component::PROCESS_NONCE}|#{index}"
      end

      # Guards the generation bump only. Fetchers read the counter without it —
      # a torn read is impossible for an Integer reference, and a fetcher that
      # misses a bump by microseconds picks it up on its next pass.
      PAUSED_GENERATION_LOCK = Mutex.new

      @paused_generation = 0

      class << self
        # Every fetcher in this process caches the paused SET against this
        # counter, so bumping it expires all of them at once.
        attr_reader :paused_generation

        # Queue#pause!/#unpause! call this. Without it a host app that pauses a
        # queue from inside a job would keep watching its own workers drain that
        # queue for up to PAUSED_TTL — the one staleness the sign-off refuses.
        def invalidate_paused_cache!
          PAUSED_GENERATION_LOCK.synchronize { @paused_generation += 1 }
        end
      end

      def initialize(capsule)
        super()
        @config = capsule
        @done = false
        @paused = nil
        @paused_generation = nil
        @paused_expires_at = 0.0
        @pending_acks = {}
        @pending_lock = ::Mutex.new
        @queue_keys = {}
        @queue_keys_pid = ::Process.pid
        @prefixed_queues = nil
        @prefixed_source = nil
      end

      # Take custody of a finished job's LREM instead of sending it now. One
      # slot per processor thread: a capsule shares a single fetcher across its
      # processors, and each thread's fetch → execute → ACK cycle is strictly
      # sequential, so a thread only ever writes its own slot. The lock is for
      # the flush paths, which drain every slot from a different thread.
      #
      # The slot holds a list rather than a single unit because a failed flush
      # can hand an older ACK back to a thread that has already deferred a newer
      # one (see #restore_pending_acks). Everywhere else it holds exactly one,
      # and the array is reused empty rather than reallocated per job.
      def defer_ack(uow)
        @pending_lock.synchronize { (@pending_acks[::Thread.current] ||= []) << uow }
      end

      # Send every held ACK now, in one pipeline of its own.
      #
      # Called from every path that stops fetching — nothing else would send
      # them — and from #bulk_requeue, where it is a correctness requirement
      # rather than an optimization: a finished job whose LREM is still pending
      # is not in Manager#hard_shutdown's in-flight list, so the requeue Lua's
      # LREM guard would still find its payload, RPUSH it onto the public
      # queue, and run it a second time on every graceful shutdown.
      def flush_pending_acks
        pending = claim_pending_acks
        # A thread whose ACK already rode a fetch leaves its queue behind empty;
        # dropping the hash those queues lived in is also how the entry of a
        # processor thread that has since died is reclaimed.
        return if pending.each_value.all?(&:empty?)

        begin
          # Apply-safe for the same reason the piggybacked copy is: a replayed
          # LREM finds the payload already gone and removes nothing, and the
          # counter DEL is idempotent by definition. Claiming it buys the drain
          # path the full connection-blip backoff.
          config.redis(idempotent: true) do |conn|
            conn.pipelined { |pipe| pending.each_value { |uows| uows.each { |uow| uow.write_ack(pipe) } } }
          end
        rescue StandardError
          restore_pending_acks(pending)
          raise
        end
      end

      # Every pass that yields no job has to cost wall-clock time: Processor#run
      # drives `process_one` in a bare `until @done` loop with no pause of its
      # own, so any nil returned instantly turns N processor threads into a hot
      # loop. The blocking BLMOVE pays that cost on the normal empty-queue path;
      # the two short-circuits below have to pay it themselves.
      def retrieve_work
        if @done
          flush_pending_acks
          sleep QUIET_PAUSE
          return nil
        end

        queues = queues_cmd
        # Nothing fetchable — every queue paused, or none configured. Back off a
        # full poll interval rather than re-running queues_cmd as fast as the CPU
        # allows. Mirrors Sidekiq's BasicFetch guard, upstream #4825.
        if queues.empty?
          flush_pending_acks
          sleep poll_interval
          return nil
        end

        walk(queues)
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
        # First and unconditional — see #flush_pending_acks. Deliberately not
        # rescued: if the ACKs could not be sent we would be requeueing jobs
        # whose completion we failed to record. Leaving them in the private
        # list for the next boot's reaper is the safer of the two.
        flush_pending_acks
        return if in_progress.nil? || in_progress.empty?

        config.redis { |conn| requeue_pipelined(conn, in_progress) }
      end

      # Prefixed queue keys (`queue:<name>`) in fetch order. Strict mode
      # preserves declaration order and, with nothing paused, hands back the
      # prebuilt array as-is — the steady-state fetch allocates nothing here,
      # matching Sidekiq's own strict path (fetch.rb:79-87). Random/weighted
      # shuffle each call — `@queues` is pre-expanded by weight in
      # Capsule#queues=, so uniform shuffle yields weighted fairness; .uniq
      # trims duplicates. Paused queues are filtered after shuffle so the
      # membership test runs on the smallest possible set.
      def queues_cmd
        paused = paused_keys
        keys = config.mode == :strict ? prefixed_queues : prefixed_queues.shuffle.uniq
        return keys if paused.empty?

        keys.reject { |key| paused.include?(key) }
      end

      # Quiet hook (Manager#quiet). Flips the drain flag so retrieve_work
      # short-circuits: once quieted, no processor can pull a fresh UoW, even
      # one sitting in the between-jobs window (Processor#run only re-checks its
      # own @done between iterations). Quiet is one-way — matches Sidekiq TSTP
      # (spec §21.3), there is no un-terminate.
      #
      # Which is exactly why it flushes: after this, retrieve_work short-circuits
      # for good, so an ACK held here would otherwise sit until shutdown.
      def terminate
        @done = true
        flush_pending_acks
      rescue StandardError => e
        # Runs on the Manager's thread mid-shutdown, where a raise would skip
        # the rest of the quiet path. The ACKs are back in their slots, so the
        # next flush point (Processor's ensure) retries them.
        handle_exception(e, { context: 'Error flushing pending acks' })
      end

      private

      # Capsule doesn't define handle_exception (it's a Configuration method);
      # override Component's delegation so error handlers fire.
      def handle_exception(ex, ctx = {})
        config.config.handle_exception(ex, ctx)
      end

      # Non-blocking pass over the fetchable queues. The pending ACK rides the
      # first LMOVE and only the first: the walk is one fetch, so a second copy
      # of the same LREM would be a wasted command on every queue we find
      # empty. By the time we fall through to BLMOVE this thread is holding
      # nothing — which is the point, since a blocking call can't join a
      # pipeline and would strand the ACK for a whole poll interval.
      def walk(queues)
        ack = take_pending_ack
        queues.each do |public_q|
          uow = lmove(public_q, ack)
          ack = nil
          return uow if uow
        end
        blmove(queues.first)
      end

      # Exactly one, even when a failed flush left this thread holding two: the
      # walk is one fetch and one pipeline, and the rest go out on the next.
      def take_pending_ack
        @pending_lock.synchronize { @pending_acks[::Thread.current]&.shift }
      end

      def claim_pending_acks
        @pending_lock.synchronize do
          held = @pending_acks
          @pending_acks = {}
          held
        end
      end

      # Put a failed flush's ACKs back rather than drop them: an LREM that is
      # never sent leaves a finished job in the private list for the next boot's
      # reaper to reclaim and run again.
      #
      # Prepended per thread rather than merged by thread: the flush runs while
      # the processors keep working, so a thread we claimed an ACK from may have
      # finished another job and deferred a second one meanwhile. Keeping only
      # one of the two re-runs whichever job lost.
      def restore_pending_acks(pending)
        @pending_lock.synchronize do
          pending.each do |thread, uows|
            next if uows.empty?

            (@pending_acks[thread] ||= []).unshift(*uows)
          end
        end
      end

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
              keys: [queue_keys(uow.queue).first, uow.queue],
              argv: [uow.job]
            )
          end
        end
      rescue RedisClient::CommandError => e
        raise unless e.message.to_s.start_with?('NOSCRIPT')

        Wurk::Lua::Loader.script_load_all(conn)
        requeue_pipelined(conn, in_progress, eval_method: :eval_with_source)
      end

      # SMEMBERS of the `paused` SET, at most once per PAUSED_TTL per fetcher
      # instead of once per fetch pass — on a busy queue that was a full round
      # trip per job spent re-confirming a set that is empty for almost every
      # install. Returns a Set for O(1) lookup against the (often
      # weighted-expanded) queue list.
      #
      # Members are unprefixed on the wire (Sidekiq Pro's `paused` SET, which we
      # never touch); the cache stores them prefixed because the only reader
      # tests them against the `queue:<name>` keys it is about to LMOVE, and
      # prefixing here is once per TTL instead of once per queue per pass.
      #
      # Monotonic clock, so an NTP step can't pin the cache open. Per instance,
      # so it dies with the fetcher and can never cross a fork.
      #
      # Processor threads share one fetcher and race here. The loser pays a
      # second SMEMBERS and overwrites with an equally fresh read; @paused is
      # published before the freshness stamps so a reader that trusts the stamps
      # can never see the value they don't belong to.
      def paused_keys
        generation = self.class.paused_generation
        now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        return @paused if @paused_generation == generation && now < @paused_expires_at

        members = config.redis(idempotent: true) { |conn| conn.call('SMEMBERS', Keys::PAUSED_SET) }
        @paused = members.to_set { |q| "#{Keys::QUEUE_PREFIX}#{q}" }
        @paused_generation = generation
        @paused_expires_at = now + PAUSED_TTL
        @paused
      end

      # `queue:<name>` for every queue this capsule serves. Rebuilt only when
      # Capsule#queues= swaps the list in — it always allocates a fresh array,
      # so identity is the whole check. Published before the source it came
      # from, so a reader that trusts the source can never see a list built
      # from a different one.
      def prefixed_queues
        source = config.queues
        return @prefixed_queues if @prefixed_source.equal?(source)

        @prefixed_queues = source.map { |q| "#{Keys::QUEUE_PREFIX}#{q}".freeze }.freeze
        @prefixed_source = source
        @prefixed_queues
      end

      # The two strings a fetch derives from a public queue key: this process's
      # private list for it (a `gethostname` syscall plus a five-part
      # interpolation) and the unprefixed name the Processor tags the job with.
      # Both are pure functions of the queue and this process's identity, so
      # they cost one build per queue rather than two per job.
      #
      # Rebuilt when the pid moves: a fetcher materialized before a fork would
      # otherwise keep claiming into a private list stamped with the parent's
      # pid, which the Reaper reads as owned by a live process — so nothing this
      # child leaves behind would ever be reclaimed.
      #
      # Copy-on-write rather than mutated in place: processor threads share one
      # fetcher and read this without a lock. A racing writer's entry can be
      # lost, and the next fetch rebuilds it.
      def queue_keys(public_q)
        pid = ::Process.pid
        if @queue_keys_pid != pid
          @queue_keys = {}
          @queue_keys_pid = pid
        end

        cache = @queue_keys
        cached = cache[public_q]
        return cached if cached

        built = [self.class.private_queue_name(public_q).freeze,
                 public_q.delete_prefix(Keys::QUEUE_PREFIX).freeze].freeze
        @queue_keys = cache.merge(public_q => built)
        built
      end

      # Both LMOVE forms claim apply-safety, so fetch keeps the full
      # connection-blip backoff the F5 split otherwise takes away: a move that
      # applied but whose reply was lost leaves the job in *this* process's
      # private list, un-ACKed — byte-for-byte the state a SIGKILL between fetch
      # and ack leaves behind, which the next boot's Reaper already reclaims. The
      # replay then pulls a different job; nothing duplicates and nothing is
      # lost, at worst one job waits out this process's lifetime.
      # A replayed ACK is a no-op (LREM removes nothing the second time, DEL is
      # already done), so folding it in costs the retry nothing.
      def lmove(public_q, ack = nil)
        priv, name = queue_keys(public_q)
        job = config.redis(idempotent: true) do |conn|
          if ack
            conn.pipelined do |pipe|
              ack.write_ack(pipe)
              pipe.call('LMOVE', public_q, priv, 'RIGHT', 'LEFT')
            end.last
          else
            conn.call('LMOVE', public_q, priv, 'RIGHT', 'LEFT')
          end
        end
        job ? unit_of_work(public_q, priv, name, job) : nil
      rescue StandardError
        # The ACK left its slot but never reached Redis. Hand it back so a
        # later flush still retires the job — otherwise a finished job sits in
        # the private list until the next boot's reaper runs it again.
        defer_ack(ack) if ack
        raise
      end

      def blmove(public_q)
        priv, name = queue_keys(public_q)
        timeout = poll_interval
        # Dedicated fetch pool, not the main one: a parked BLMOVE holds its slot
        # for the whole block window, so routing it here keeps idle fetchers from
        # starving the main pool's background loops (#101). redis-client's
        # connection_timeout helper (connection_mixin.rb:87-93) adds config.read_timeout
        # to the blocking call timeout, ensuring the socket read timeout won't fire
        # while BLMOVE is legitimately blocked.
        job = config.fetch_redis(idempotent: true) do |conn|
          conn.blocking_call(timeout, 'BLMOVE', public_q, priv, 'RIGHT', 'LEFT', timeout)
        end
        job ? unit_of_work(public_q, priv, name, job) : nil
      end

      # Both fetch paths hand the unit every string its Processor and its ACK
      # will need, so neither re-derives one per job.
      def unit_of_work(public_q, priv, name, job)
        UnitOfWork.new(queue: public_q, queue_name: name, private_queue: priv,
                       job: job, config: config, fetcher: self)
      end

      # BLMOVE block timeout for an empty poll. `config.fetch_poll_interval`
      # (Pro super_fetch §3.3) overrides the TIMEOUT default; nil → TIMEOUT.
      def poll_interval
        config.fetch_poll_interval || TIMEOUT
      end
    end
  end
end
