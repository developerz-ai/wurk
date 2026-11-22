# frozen_string_literal: true

module Wurk
  # What a job still owes Redis after its `perform` returned and the bookkeeping
  # behind it failed: a sidekiq-unique-jobs lock and a batch's success ack.
  #
  # The job is finished and is never run again for this, since a second run of a
  # bank login or an email is the harm. So the owed writes wait here, in this
  # process, and every Processor retries them before its next fetch. That costs
  # no thread and no sleep during the outage, and they land as soon as Redis
  # answers. A process that exits first says which locks it left (#give_up): the
  # gem's reaper or the lock's TTL clears them.
  class FinishedJobCleanup
    # Names the job, with the Redis error as its `cause`.
    class BookkeepingFailed < ::StandardError; end

    STORE_ERRORS = [RedisClient::Error, ConnectionPool::Error, ConnectionPool::TimeoutError].freeze
    # Past this many owed jobs the oldest is reported and dropped.
    MEMORY = 10_000
    RETRY_EVERY = 1.0
    RUN_SUFFIX = ':RUN'
    # This lock type is meant to outlive the job, until its TTL.
    KEEPS_LOCK = 'until_expired'

    Entry = Struct.new(:job, :pool, :config)

    @entries = []
    @lock = ::Mutex.new
    @draining = ::Mutex.new
    @next_try = 0.0

    class << self
      def store_error?(error) = STORE_ERRORS.any? { |klass| error.is_a?(klass) }

      # Reports the failure, tries the owed writes once, keeps what did not land.
      def settle(job, error, pool:, config:)
        report(job, error, config)
        entry = Entry.new(job, pool, config)
        return unless owes_anything?(job)
        return if attempt?(entry)

        remember(entry)
        config.logger.error { "#{describe(job)}: waiting for Redis to finish its cleanup" }
      end

      # Hot path: one empty check per fetch while nothing is owed.
      def drain
        return if @entries.empty? || monotonic < @next_try
        return unless @draining.try_lock

        begin
          drain_entries
        ensure
          @draining.unlock
        end
      end

      # The process is stopping: one last try, then say what is left.
      def give_up
        return if @entries.empty?

        @next_try = 0.0
        drain
        @lock.synchronize { @entries.slice!(0..) }.each { |entry| warn_left(entry) }
      end

      def pending = @lock.synchronize { @entries.size }

      def reset!
        @lock.synchronize { @entries.clear }
        @next_try = 0.0
      end

      private

      def drain_entries
        while (entry = @lock.synchronize { @entries.first })
          unless attempt?(entry)
            @next_try = monotonic + RETRY_EVERY
            return
          end
          @lock.synchronize { @entries.delete_at(@entries.index { |held| held.equal?(entry) } || @entries.size) }
          entry.config.logger.info { "#{describe(entry.job)}: cleanup finished after the Redis failure" }
        end
      end

      # true when nothing more can be done for this entry. Idempotent, so an
      # entry half done by an earlier try is safe to run again.
      def attempt?(entry)
        release_unique_locks(entry.job)
        ack_batch(entry.job, entry.pool)
        true
      rescue StandardError => e
        return false if store_error?(e)

        entry.config.handle_exception(e, { context: "#{describe(entry.job)}: cleanup failed", job: entry.job })
        true
      end

      # Locksmith#unlock only drops a lock this jid holds. Both digests: an
      # until_and_while_executing job takes its base lock back when an error
      # crosses it, on top of the `:RUN` lock it may still hold.
      def release_unique_locks(job)
        digests(job).each { |digest| ::SidekiqUniqueJobs::Locksmith.new(job.merge('lock_digest' => digest)).unlock }
      end

      def digests(job)
        digest = job['lock_digest']
        return [] unless digest && job['lock'].to_s != KEEPS_LOCK && defined?(::SidekiqUniqueJobs::Locksmith)

        base = digest.delete_suffix(RUN_SUFFIX)
        [base, "#{base}#{RUN_SUFFIX}"]
      end

      # A replayed ack removes nothing, and the callback markers absorb a second
      # fire (Batch::ServerMiddleware#ack_success).
      def ack_batch(job, pool)
        bid = job['bid']
        return unless bid

        _removed, pending, live, kids = pool.with { |conn| Batch.ack_success(conn, bid, job['jid']) }
        Batch::Callbacks.maybe_fire(bid, pending: pending, live: live, kids: kids)
      end

      def owes_anything?(job) = job['bid'] || digests(job).any?

      def remember(entry)
        dropped = @lock.synchronize do
          @entries << entry
          @entries.shift if @entries.size > MEMORY
        end
        warn_left(dropped) if dropped
      end

      def warn_left(entry)
        entry.config.logger.error do
          "#{describe(entry.job)}: cleanup never reached Redis. Locks left: #{digests(entry.job).join(', ')}; " \
            'the sidekiq-unique-jobs reaper or the lock TTL clears them. Batch: ' \
            "#{entry.job['bid'] || 'none'}"
        end
      end

      def report(job, error, config)
        raise BookkeepingFailed, "#{describe(job)}: Redis failed after perform returned, not running it again " \
                                 "(#{error.class}: #{error.message}). Locks: #{digests(job).join(', ')}", cause: error
      rescue BookkeepingFailed => e
        config.handle_exception(e, { context: 'Bookkeeping failed after perform', job: job })
      end

      def describe(job) = "#{job['class']} JID-#{job['jid']}"

      def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
