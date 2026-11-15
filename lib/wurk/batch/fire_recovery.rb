# frozen_string_literal: true

require_relative '../component'
require_relative '../keys'
require_relative '../timer_loop'

module Wurk
  class Batch
    # Cluster-wide re-drive for batch callbacks whose fire was lost.
    #
    # The drain-observing scripts (`batch_ack_success`, `batch_ack_complete`,
    # `batch_kid_done`) ZADD the drained bid into `Keys::BATCH_FIRES` in the
    # same atomic step that observes the drain, and `Callbacks.maybe_fire`
    # ZREMs it once its fire pass completed. Between those two moments the
    # caller can die — a chaos outage that eats every `Callbacks.retrying`
    # attempt in its ~0.05s backoff window, or a kill mid-fire — and then the
    # entry is the only thing left that knows the callbacks are still owed.
    # This loop is what re-drives those entries, on any process that survives:
    # the soak's processes recover from exactly the outage the in-process
    # re-drive cannot, so the drain times out instead of stranding.
    #
    # One sweep an interval, gated by a cluster lock so about one process
    # sweeps. The lock is not a nicety: `re_drive` → `maybe_fire` dedups on
    # the markers, so two sweeps racing one entry fire the callbacks at most
    # once *within* a single Redis outage — but two completions landing on
    # either side of it are two enqueues no marker can see, and the ledger
    # fails the verdict on exactly that. Never double-fire.
    #
    # `:death` deliberately stays out of this: the death path claims its
    # notify marker before enqueueing (at-most-once, see `fire_death`), and a
    # claim whose enqueue was lost is the documented residual, not something
    # recovery may duplicate.
    #
    # Entries are retired on the batch clock, not a fire-index one: a sweep
    # drops entries older than `Batch::DEFAULT_EXPIRY_SECONDS`, the same TTL
    # the batch data itself lives under, so an entry can only outlive its
    # batch by that much.
    class FireRecovery
      include Component

      # Sweep cadence in seconds. 60 matches the Reaper's — a drained batch
      # whose fire is stranded waits at most grace + interval, well inside the
      # drain timeout any caller of `Batch#jobs` sits behind.
      DEFAULT_INTERVAL = 60

      # Entries younger than this are left to the caller's in-process re-drive
      # (`Callbacks.retrying`), which has already succeeded for every fire
      # that is merely slow; the durable entry exists for the fire that was
      # *lost*. Racing the in-process attempts would only spend round trips
      # duplicating work the markers then dedup.
      GRACE = 30

      # Re-drives per sweep. Each re_drive is a handful of round trips; a cap
      # keeps one sweep with a huge backlog from holding the loop (and the
      # cluster lock) open, and the next sweep picks up the rest a minute
      # later.
      SWEEP_LIMIT = 25

      # The lock lapses before the winner's next tick, or a sole survivor
      # would still find its own lock there and sweep every second interval.
      LOCK_TTL_RATIO = 0.8

      LOCK_KEY = 'batch:fires:lock'

      THREAD_NAME = 'wurk-batch-fire-recovery'

      attr_reader :interval

      def initialize(config, interval: DEFAULT_INTERVAL, lock_key: LOCK_KEY, grace: GRACE)
        @config = config
        @interval = interval
        @lock_key = lock_key
        @grace = grace
        @timer = TimerLoop.new(interval)
        @thread = nil
      end

      # Spawns the sweep loop. The loop waits one interval before its first
      # sweep so booting processes don't dogpile Redis and so an un-started
      # launcher in a unit test never touches the keyspace.
      def start
        return @thread if @thread

        @timer.reset
        @thread = safe_thread(THREAD_NAME) { @timer.run { tick } }
      end

      # Cleared only on a confirmed join (Thread#join returns nil on timeout):
      # a wedged thread must stay tracked so #start's guard returns it instead
      # of calling @timer.reset, which would un-terminate the loop it is still
      # inside and leave two sweeps racing the same entries without the lock
      # stopping them.
      def terminate
        @timer.terminate
        @thread = nil if @thread&.join(TimerLoop::JOIN_TIMEOUT)
      end

      def running?
        !@thread.nil? && @thread.alive?
      end

      # One loop tick: a sweep when this process wins the per-interval lock.
      def tick
        sweep if acquire_lock?
      rescue StandardError => e
        handle_exception(e, { context: THREAD_NAME })
      end

      # One sweep: re-drive every entry past the grace, then retire the ones
      # whose batch is beyond the batch clock. Public so boot paths and tests
      # can drive a deterministic pass without the cluster lock.
      def sweep
        now = Batch.drain_epoch
        bids = redis(idempotent: true) do |conn|
          conn.call('ZRANGEBYSCORE', Keys::BATCH_FIRES, '-inf', "(#{now - @grace}", 'LIMIT', 0, SWEEP_LIMIT)
        end
        bids.each do |bid|
          begin
            Callbacks.re_drive(bid)
          rescue StandardError => e
            handle_exception(e, { context: "#{THREAD_NAME}: re_drive failed", bid: bid })
          end
        end

        redis(idempotent: true) do |conn|
          conn.call('ZREMRANGEBYSCORE', Keys::BATCH_FIRES, '-inf', now - Batch::DEFAULT_EXPIRY_SECONDS)
        end
        bids.length
      end

      private

      def acquire_lock?
        ttl = (@interval * LOCK_TTL_RATIO).ceil
        redis do |conn|
          conn.call('SET', @lock_key, '1', 'NX', 'EX', ttl)
        end == 'OK'
      end
    end
  end
end
