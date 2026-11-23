# frozen_string_literal: true

module Wurk
  module UniqueJobs
    # What happens to a job that meets a lock held by another: `on_conflict:`,
    # one strategy, or `{ client: ..., server: ... }`.
    module OnConflict
      class Strategy
        include Logging
        include Reflectable

        attr_reader :item

        def initialize(item, _redis_pool = nil)
          @item = item
        end

        def call = raise(NotImplementedError, 'needs to be implemented in child class')
        def replace? = false
      end

      # No `on_conflict:`: the duplicate is dropped without a word.
      class NullStrategy < Strategy
        def call; end
      end

      class Log < Strategy
        def call
          log_info("Skipping job with id (#{item[JID]}) because lock_digest: (#{item[LOCK_DIGEST]}) already exists")
        end
      end

      class Raise < Strategy
        def call = raise(Conflict, item)
      end

      # The duplicate goes to the dead set, without death handlers: those would
      # release the digest, which is the holder's lock.
      class Reject < Strategy
        def call
          log_info { "Adding dead #{item[CLASS]} job #{item[JID]}" }
          Wurk::DeadSet.new.kill(Wurk.dump_json(item), notify_failure: false)
        end
      end

      # Pushes the job again `schedule_in` seconds out (option, default 5), with
      # `rescheduled` so the client middleware lets that push through unlocked.
      class Reschedule < Strategy
        include JobOptions

        def initialize(item, redis_pool = nil)
          super
          self.job_class = item[CLASS]
        end

        def call
          return reflect(:unknown_sidekiq_worker, item) unless sidekiq_job_class?

          jid = job_class.set(queue: item[QUEUE].to_sym, RESCHEDULED => true).perform_in(schedule_in, *item[ARGS])
          reflect(jid ? :rescheduled : :reschedule_failed, item)
        end

        def schedule_in = job_class.get_sidekiq_options['schedule_in'] || 5
      end

      # Deletes the queued, scheduled or retrying job that holds the digest and
      # its lock, then lets this push take the lock in its place.
      class Replace < Strategy
        def replace? = true

        def call(&block)
          return unless (deleted_job = delete_job_by_digest)

          log_info("Deleted job: #{deleted_job}")
          count = Digests.new.delete_by_digest(item[LOCK_DIGEST], runtime: false)
          log_info("Deleted `#{count}` keys for #{item[LOCK_DIGEST]}") if count
          block&.call
        end

        private

        def delete_job_by_digest
          keys = ["#{QUEUE}:#{item[QUEUE]}", SCHEDULE, RETRY, DIGESTS]
          UniqueJobs.redis do |conn|
            Script.call(:unique_jobs_delete_job_by_digest, conn, keys: keys, argv: [item[LOCK_DIGEST]])
          end
        end
      end

      STRATEGIES = { log: Log, raise: Raise, reject: Reject, replace: Replace, reschedule: Reschedule }.freeze

      def self.strategies = UniqueJobs.strategies

      def self.find_strategy(strategy)
        return NullStrategy unless strategy

        strategies.fetch(strategy.to_sym) do
          UniqueJobs.logger.warn(
            "No matching implementation for strategy: #{strategy}, returning OnConflict::NullStrategy. " \
            "Available strategies are (#{strategies.inspect})"
          )
          NullStrategy
        end
      end
    end
  end
end
