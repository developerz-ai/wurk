# frozen_string_literal: true

require_relative 'component'
require_relative 'keys'
require_relative 'lua'
require_relative 'lua/loader'
require_relative 'client'
require_relative 'process_set'
require_relative 'timer_loop'

module Wurk
  # Promotes due jobs from the `retry` and `schedule` sorted sets back onto
  # their target queues. One Poller thread per process; collectively they
  # drain both SETS through a Lua claim (loaded via the EVALSHA cache, retried
  # once on NOSCRIPT). Polling cadence scales with cluster
  # size so total scheduler traffic stays constant as processes are added.
  #
  # Spec: docs/target/sidekiq-free.md §16. Pluggable via `config[:scheduled_enq]`.
  module Scheduled
    SETS = %w[retry schedule].freeze

    # Source must match Wurk::Lua::ZPOPBYSCORE byte-for-byte: they share a SHA.
    LUA_ZPOPBYSCORE = Wurk::Lua::ZPOPBYSCORE

    # Drains both SETS each call, running every promoted job through the client
    # middleware chain.
    #
    # Claims rather than pops: `scheduled_claim` rescores due members to a lease
    # expiry, the job is pushed, and only then is the member ZREMed. Between any
    # two of those steps the job exists in its set, so a lost reply (the re-sent
    # claim just leases a further batch), an out-of-memory push or a kill -9 ends
    # in a re-promotion once the lease lapses. The failure mode is therefore a
    # duplicate and a delay of up to CLAIM_LEASE, never a lost job. Other pollers
    # skip a claimed member because its score has left their due window.
    class Enq
      include Component

      # Public per spec §16; the claim replaced it here.
      LUA_ZPOPBYSCORE = Wurk::Lua::ZPOPBYSCORE

      # Bounds what one crash can duplicate. The ZREMs share one round trip per
      # batch, which is what makes this cheaper than a pop per job.
      CLAIM_BATCH = 10
      # Seconds until a claimed member is due again. Far above a healthy batch,
      # which takes milliseconds, so a second poller does not re-promote it.
      CLAIM_LEASE = 60

      TRANSIENT_ERRORS = [RedisClient::Error, ConnectionPool::TimeoutError].freeze
      # The whole store is refusing, not this job. A plain CommandError with one of
      # these prefixes says the same as OutOfMemoryError (Dragonfly's reply at
      # maxmemory is `ERR Out of memory`).
      STORE_REFUSAL = /\A(?:LOADING|ERR Out of memory|OOM|MASTERDOWN|MISCONF|BUSY)/

      def initialize(container)
        @config = container
        @done = false
        @client = Client.new(config: container)
        @lease = container[:scheduled_claim_lease] || CLAIM_LEASE
      end

      # `now` is captured once per set so a slow loop on one ZSET can't keep
      # grabbing newly-scheduled jobs from a moving window.
      def enqueue_jobs(sorted_sets = SETS)
        sorted_sets.each { |sset| drain_set(sset) }
      end

      def terminate
        @done = true
      end

      private

      # Claim and ZREM under their own checkouts, push outside them: `@client.push`
      # checks out its own connection, so nesting it would hold two per job and
      # halve the pool's effective concurrency under load.
      def drain_set(sset)
        now = real_time.to_s
        until @done
          claimed = claim_due(sset, now)
          break unless promote_batch(sset, claimed) && claimed.size == CLAIM_BATCH
        end
      end

      # An error here leaves this claim's outcome unknown, which is harmless: every
      # member is still in the set. Reporting and ending this set's drain keeps the
      # sibling set draining on this tick. A store refusing writes (out of memory)
      # lands here too and simply waits, with every due job left in place.
      def claim_due(sset, now)
        @config.redis do |conn|
          Wurk::Lua::Loader.eval_cached(conn, :scheduled_claim, keys: [sset],
                                                                argv: [now, @lease.to_s, CLAIM_BATCH.to_s])
        end
      rescue *TRANSIENT_ERRORS => e
        handle_exception(e, { context: 'scheduler_pop', set: sset })
        []
      end

      # True when the whole batch was handled, so the drain may claim another.
      #
      # Unbuffered, because the ZREM below is only safe once Redis holds the job. With
      # `reliable_push!` a push could otherwise land in memory and return, and a crash
      # would lose the only copy.
      def promote_batch(sset, claimed)
        deadline = mono_ms + (@lease * 500)
        pushed = []
        Client::Buffered.unbuffered do
          claimed.each_with_index do |jobstr, index|
            if @done || mono_ms > deadline || !push_promoted(jobstr, sset, pushed)
              release(sset, claimed.drop(index))
              return false
            end
          end
        end
        true
      ensure
        settle(sset, pushed)
      end

      # False when the store is failing, so the rest of the batch is not attempted:
      # each further push would wait out the same outage, past the lease, and race
      # the poller that re-claims it.
      #
      # An error from this one job's push (WRONGTYPE on its queue key, a Lua error
      # from a middleware) must not hold back the others. It stays in its set under
      # the lease, so it is retried and reported about once a lease, not once a poll.
      def push_promoted(jobstr, sset, pushed)
        @client.push(Wurk.load_json(jobstr))
        pushed << jobstr
        true
      rescue *TRANSIENT_ERRORS => e
        handle_exception(e, { context: 'scheduler_promote', set: sset })
        !store_refusing?(e)
      rescue StandardError => e
        handle_exception(e, { context: 'scheduler_promote', set: sset })
        bury(jobstr, sset)
        true
      end

      # An undecodable payload, a payload the client rejects or a raising middleware
      # fails the same way on every retry, so the member moves to the dead set,
      # scored `now` like a kill and byte-identical to what was claimed: the same
      # place ReliableEnq's script puts a member it cannot promote.
      def bury(jobstr, sset)
        # Two commands, no MULTI: a server that refuses the ZADD mid-transaction
        # (Dragonfly at maxmemory) still applies the ZREM, and the member is gone.
        # A crash between them costs one more trip through here.
        @config.redis(idempotent: true) do |conn|
          conn.call('ZADD', Keys::DEAD, real_time.to_s, jobstr)
          conn.call('ZREM', sset, jobstr)
        end
      rescue *TRANSIENT_ERRORS => e
        handle_exception(e, { context: 'scheduler_restore', set: sset })
      end

      # Hands unpushed members straight back to the next poll. Best effort: if this
      # fails too, the lease brings them back.
      def release(sset, members)
        return if members.empty?

        now = real_time.to_s
        @config.redis(idempotent: true) do |conn|
          conn.call('ZADD', sset, 'XX', *members.flat_map { |member| [now, member] })
        end
      rescue *TRANSIENT_ERRORS => e
        handle_exception(e, { context: 'scheduler_restore', set: sset })
      end

      # A failure here means these jobs run again when the lease lapses. That is the
      # accepted duplicate; dropping the member before the push is the loss it avoids.
      def settle(sset, pushed)
        return if pushed.empty?

        @config.redis(idempotent: true) { |conn| conn.call('ZREM', sset, *pushed) }
      rescue *TRANSIENT_ERRORS => e
        handle_exception(e, { context: 'scheduler_settle', set: sset })
      end

      def store_refusing?(error)
        return true unless error.is_a?(RedisClient::CommandError)

        error.is_a?(RedisClient::OutOfMemoryError) || error.message.match?(STORE_REFUSAL)
      end

      def real_time
        ::Process.clock_gettime(::Process::CLOCK_REALTIME)
      end
    end

    # Reliable variant of Enq (Pro §4): faster, but it skips client middleware
    # on promotion. ReliableEnq promotes every due job from each set onto its target
    # queue in a single atomic Lua (ZRANGEBYSCORE → LPUSH queue:<q> → ZREM),
    # so there is no window where a job exists in neither place. Swapped in by
    # `config.reliable_scheduler!` via the `scheduled_enq` seam.
    #
    # Spec: docs/target/sidekiq-pro.md §4.
    class ReliableEnq
      include Component

      # Batched: each Lua call promotes at most this many members (the script
      # runs atomically, so one giant sweep would stall Redis for every
      # client). `promote` loops until a short batch signals the backlog is
      # dry, stopping early on terminate.
      PROMOTE_BATCH = 500

      def initialize(container)
        @config = container
        @done = false
      end

      def enqueue_jobs(sorted_sets = SETS)
        @config.redis do |conn|
          sorted_sets.each { |sset| promote(conn, sset) }
        end
      end

      def terminate
        @done = true
      end

      private

      def promote(conn, sset)
        loop do
          promoted = Wurk::Lua::Loader.eval_cached(
            conn,
            :reliable_schedule_promote,
            keys: [sset, Keys::QUEUES_SET, Keys::DEAD],
            argv: [real_time.to_s, Keys::QUEUE_PREFIX, real_ms.to_s, PROMOTE_BATCH.to_s]
          ).to_i
          break if promoted < PROMOTE_BATCH || @done
        end
      end

      def real_time
        ::Process.clock_gettime(::Process::CLOCK_REALTIME)
      end
    end

    # Single thread that wakes on a randomized interval, drains both ZSETs,
    # then sleeps again. Random spread prevents the cluster from dogpiling
    # Redis at the top of each cadence.
    class Poller
      include Component

      INITIAL_WAIT = 10
      # Without this, a fleet booted together sends its first sweeps as one burst.
      INITIAL_JITTER = 5.0

      attr_accessor :rnd

      def initialize(config)
        @config = config
        @enq = (config[:scheduled_enq] || Enq).new(config)
        @done = false
        @mutex = ::Mutex.new
        @sleeper = ::ConditionVariable.new
        @thread = nil
        @rnd = ::Random.new
        @last_cleanup_ms = 0
      end

      # Spawns the scheduler thread. The initial wait delays and spreads the first
      # sweep so a fleet-wide deploy doesn't have every process hit Redis at once.
      def start
        @thread ||= safe_thread('scheduler') do # rubocop:disable Naming/MemoizedInstanceVariableName
          initial_wait
          until @done
            enqueue
            wait
          end
          logger.info('Scheduler exiting...')
        end
      end

      # Idempotent. Wakes the sleeping thread so it observes @done and exits.
      # Also propagates the stop signal to @enq so any in-flight drain loop
      # short-circuits instead of running to completion. Terminal, not a pause:
      # @enq's stop flag is one-way, so this poller never polls again.
      #
      # Joins before returning — the caller (Launcher#quiet, then #stop) clears
      # the heartbeat right after, and a sweep still in flight would promote
      # jobs on behalf of a process that no longer exists.
      #
      # Cleared only on a confirmed join (Thread#join returns nil on timeout):
      # a wedged sweep must stay tracked so #start's ||= guard returns it
      # rather than spawning a second scheduler thread alongside it.
      def terminate
        @mutex.synchronize do
          @done = true
          @enq.terminate
          @sleeper.signal
        end
        @thread = nil if @thread&.join(TimerLoop::JOIN_TIMEOUT)
      end

      # Called on every wake. Any raise inside the Enq is reported and the
      # loop continues — a transient Redis blip must not kill the scheduler.
      def enqueue
        @enq.enqueue_jobs
      rescue StandardError => e
        handle_exception(e, { context: 'scheduler' })
      end

      private

      # Overridable via `config[:scheduler_initial_wait]`, taken exactly as given
      # (tests want a near-zero first sweep).
      def initial_wait
        wait = @config[:scheduler_initial_wait] || (INITIAL_WAIT + (@rnd.rand * INITIAL_JITTER))
        @mutex.synchronize do
          @sleeper.wait(@mutex, wait) unless @done
        end
      end

      def wait
        interval = poll_interval_or_fallback
        @mutex.synchronize do
          @sleeper.wait(@mutex, interval) unless @done
        end
      end

      # The interval reads the process count from Redis (SCARD / ProcessSet
      # prune), so a blip here would otherwise kill the scheduler thread for
      # good — retries and scheduled jobs then never promote again in this
      # process. Report it and sleep one unscaled average instead; the next
      # wake retries the read. Computed outside the mutex so #terminate is never
      # held behind a Redis timeout.
      def poll_interval_or_fallback
        random_poll_interval
      rescue StandardError => e
        handle_exception(e, { context: 'scheduler_wait' })
        poll_interval_average(1)
      end

      # interval = process_count * average_scheduled_poll_interval
      # <10 procs: jitter `interval * rand + interval/2`
      # ≥10 procs: jitter `interval * rand * 2`
      # The two regimes produce comparable expected wait times but the
      # high-cluster form widens the spread so 100+ processes don't cluster.
      def random_poll_interval
        count = process_count
        interval = poll_interval_average(count)
        if count < 10
          (interval * @rnd.rand) + (interval / 2.0)
        else
          interval * @rnd.rand * 2
        end
      end

      def poll_interval_average(count)
        @config[:poll_interval_average] || scaled_poll_interval(count)
      end

      def scaled_poll_interval(count)
        count * @config[:average_scheduled_poll_interval]
      end

      # SCARD on the `processes` SET, floor of 1 so a freshly-booted process
      # (not yet in the set) still computes a non-zero interval.
      def process_count
        pcount = cleanup
        pcount = 1 if pcount < 1
        pcount
      end

      # Returns the current `processes` SCARD. Rate-limited to 1/min: the
      # full ProcessSet prune is expensive (SMEMBERS + per-id HGET), so we
      # only invoke it when at least 60s have passed; intermediate calls
      # just SCARD and trust the previous prune.
      def cleanup
        @config.redis do |conn|
          if mono_ms - @last_cleanup_ms > 60_000
            @last_cleanup_ms = mono_ms
            ProcessSet.new(true).size
          else
            conn.call('SCARD', Keys::PROCESSES)
          end
        end
      end
    end
  end
end
