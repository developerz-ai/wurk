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
  # drain both SETS via an atomic Lua pop-by-score (loaded via the EVALSHA
  # cache, retried once on NOSCRIPT). Polling cadence scales with cluster
  # size so total scheduler traffic stays constant as processes are added.
  #
  # Spec: docs/target/sidekiq-free.md §16. Pluggable via `config[:scheduled_enq]`.
  module Scheduled
    SETS = %w[retry schedule].freeze

    # Atomic pop-by-score for retry/schedule. Source must match
    # Wurk::Lua::ZPOPBYSCORE byte-for-byte — they share the same SHA.
    LUA_ZPOPBYSCORE = Wurk::Lua::ZPOPBYSCORE

    # Drains both SETS each call. Iterates per-set inside a single pooled
    # checkout so the EVALSHA + LPUSH loop avoids re-checkout per job.
    class Enq
      include Component

      LUA_ZPOPBYSCORE = Wurk::Lua::ZPOPBYSCORE

      def initialize(container)
        @config = container
        @done = false
        @client = Client.new(config: container)
      end

      # Pops every due job from each sorted set and re-pushes through the
      # client. `now` is captured once per set so a slow loop on one ZSET
      # can't keep grabbing newly-scheduled jobs from a moving window.
      def enqueue_jobs(sorted_sets = SETS)
        sorted_sets.each { |sset| drain_set(sset) }
      end

      def terminate
        @done = true
      end

      private

      # Pop under one checkout (the pooled EVALSHA loop), push outside it —
      # `@client.push` checks out its own connection, so nesting it inside
      # `@config.redis` would hold two checkouts from the same pool at once
      # per job, halving effective pool concurrency under load.
      def drain_set(sset)
        now = real_time.to_s
        loop do
          break if @done

          jobstr = pop_due(sset, now)
          break unless jobstr

          push_promoted(jobstr, sset)
        end
      end

      # ZPOPBYSCORE is destructive and carries its result in the reply, so this
      # block never claims apply-safety: a replay discards whatever the lost
      # reply already removed. The pool therefore raises on a Read-/WriteTimeout,
      # which leaves the outcome of *this* pop unknown — a due job may or may not
      # have come off the ZSET. Report it and end this set's drain (the nil makes
      # #drain_set break) rather than pop again blind; a job caught in that window
      # falls into the same pop→push loss the default scheduler already documents
      # on #push_promoted, and `reliable_scheduler!` (ReliableEnq) is the loss-free
      # fix. Rescuing here rather than around #drain_set keeps the sibling set
      # draining on this tick.
      def pop_due(sset, now)
        @config.redis { |conn| Wurk::Lua::Loader.eval_cached(conn, :zpopbyscore, keys: [sset], argv: [now]) }
      rescue RedisClient::ConnectionError => e
        handle_exception(e, { context: 'scheduler_pop', set: sset })
        nil
      end

      # A raising `@client.push` (bad payload, transient Redis error) must not
      # abort the drain and strand the remaining due jobs until the next poll —
      # rescue per-job, report, continue. The already-popped job IS lost here
      # (ZPOPBYSCORE removed it); that pop→push loss window is the default
      # scheduler's known tradeoff — `reliable_scheduler!` (ReliableEnq) is the
      # loss-free fix, so we don't re-engineer around it here.
      def push_promoted(jobstr, sset)
        @client.push(Wurk.load_json(jobstr))
      rescue StandardError => e
        handle_exception(e, { context: 'scheduler_promote', set: sset })
      end

      def real_time
        ::Process.clock_gettime(::Process::CLOCK_REALTIME)
      end
    end

    # Reliable variant of Enq (Pro §4). The default Enq pops then pushes —
    # a crash between the ZPOPBYSCORE and the client push loses the job.
    # ReliableEnq instead promotes every due job from each set onto its target
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
            keys: [sset, Keys::QUEUES_SET],
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

      # Spawns the scheduler thread. INITIAL_WAIT delays the first sweep so
      # a fleet-wide deploy doesn't have every freshly-booted process hit
      # Redis simultaneously.
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

      # INITIAL_WAIT (10s) staggers the fleet's first sweep after a deploy so
      # freshly-booted processes don't hit Redis in unison. Overridable via
      # `config[:scheduler_initial_wait]` (tests want a near-zero first sweep).
      def initial_wait
        wait = @config[:scheduler_initial_wait] || INITIAL_WAIT
        @mutex.synchronize do
          @sleeper.wait(@mutex, wait) unless @done
        end
      end

      def wait
        @mutex.synchronize do
          @sleeper.wait(@mutex, random_poll_interval) unless @done
        end
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
