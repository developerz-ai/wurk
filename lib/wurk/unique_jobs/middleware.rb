# frozen_string_literal: true

module Wurk
  module UniqueJobs
    module Middleware
      # What both sides share: whether this payload is unique, and its lock.
      module Base
        include JobOptions
        include Logging

        attr_reader :item

        private

        def unique?
          return false unless UniqueJobs.enabled?
          return true if UniqueJobs.native?

          UniqueJobs.warn_standing_down
          false
        end

        def lock_type = @lock_type ||= options[LOCK] || item[LOCK]

        def options
          @options ||= begin
            opts = default_job_options.dup
            opts.merge!(job_options) if sidekiq_job_class?
            UniqueJobs.deep_stringify(opts)
          end
        end

        def lock_instance
          @lock_instance ||= lock_class.new(item, after_unlock_hook)
        end

        def lock_class
          UniqueJobs.locks.fetch(lock_type.to_sym) { raise UnknownLock, "No implementation for `lock: :#{lock_type}`" }
        end

        def with_context(side, &)
          Wurk::Context.with('uniquejobs' => side, lock_type.to_s => item[LOCK_DIGEST], &)
        end

        # Fills the payload's lock fields when it is a unique job; false when not.
        def lockable?(worker_class, item)
          @item = item
          @lock_type = @options = @lock_instance = nil
          self.job_class = worker_class
          return false if item.delete(RESCHEDULED) || !unique? || !lock_type

          Job.prepare(item)
          true
        end
      end

      # Takes the lock at push; a conflict goes to the job's `on_conflict`, and a
      # push it refuses returns nil, like any halting client middleware.
      class Client
        include Wurk::Middleware::ClientMiddleware
        include Base
        include Reflectable

        def call(worker_class, item, _queue, _redis_pool = nil)
          return yield unless lockable?(worker_class, item)

          with_context(:client) do
            lock_instance.lock do
              reflect(:locked, item)
              return yield
            end
          end
        end
      end

      # Runs `perform` inside the lock type's server half: unlock after, unlock
      # before, or hold a runtime lock around it.
      class Server
        include Wurk::Middleware::ServerMiddleware
        include Base

        def call(worker, item, _queue, &)
          return yield unless lockable?(worker, item)

          with_context(:server) { lock_instance.execute(&) }
        end
      end
    end

    # `SidekiqUniqueJobs::Server.configure(config)`: the reaper on startup and the
    # death handler that frees a dead job's lock.
    class Server
      DEATH_HANDLER = lambda do |job, _exception|
        digest = job['lock_digest']
        Digests.new.delete_by_digest(digest) if digest
      end

      def self.configure(config)
        config.on(:startup) { start }
        config.on(:shutdown) { stop }
        config.death_handlers << DEATH_HANDLER unless config.death_handlers.include?(DEATH_HANDLER)
      end

      def self.start = Orphans::Manager.start
      def self.stop = Orphans::Manager.stop
      def self.death_handler = DEATH_HANDLER
    end
  end
end
