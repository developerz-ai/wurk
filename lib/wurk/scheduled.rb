# frozen_string_literal: true

require_relative 'component'
require_relative 'keys'
require_relative 'lua'
require_relative 'lua/loader'
require_relative 'client'
require_relative 'process_set'

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
        @config.redis do |conn|
          sorted_sets.each { |sset| drain_set(conn, sset) }
        end
      end

      def terminate
        @done = true
      end

      private

      def drain_set(conn, sset)
        now = real_time.to_s
        loop do
          break if @done

          jobstr = Wurk::Lua::Loader.eval_cached(conn, :zpopbyscore, keys: [sset], argv: [now])
          break unless jobstr

          @client.push(Wurk.load_json(jobstr))
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
      def terminate
        @mutex.synchronize do
          @done = true
          @sleeper.signal
        end
      end

      # Called on every wake. Any raise inside the Enq is reported and the
      # loop continues — a transient Redis blip must not kill the scheduler.
      def enqueue
        @enq.enqueue_jobs
      rescue StandardError => e
        handle_exception(e, { context: 'scheduler' })
      end

      private

      def initial_wait
        @mutex.synchronize do
          @sleeper.wait(@mutex, INITIAL_WAIT) unless @done
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
