# frozen_string_literal: true

require_relative '../middleware'
require_relative '../job'
require_relative '../job_retry'

module Wurk
  module Middleware
    # Server middleware. Catches `Wurk::Job::Interrupted` raised by an
    # IterableJob mid-iteration (or any cooperatively-cancelled job),
    # re-pushes the job to the head of its queue so it resumes from the
    # persisted cursor, and raises `Wurk::JobRetry::Skip` so the retry
    # layer treats this as a clean exit rather than an error.
    #
    # The re-push uses LPUSH (head of queue) so the same job is the next
    # one to be fetched after restart. The job JSON is unchanged: cursor
    # state lives in the `it-<jid>` HASH (see IterableJob persistence),
    # not in the payload.
    #
    # Auto-registered at the top of the server chain when this file is
    # required. Top-of-chain is important: a downstream middleware must
    # not swallow the Interrupted before we see it.
    #
    # Spec: docs/target/sidekiq-free.md §10.3.
    class InterruptHandler
      include Wurk::Middleware::ServerMiddleware

      def call(_job_instance, job, queue)
        yield
      rescue Wurk::Job::Interrupted
        repush(job, queue)
        raise Wurk::JobRetry::Skip
      end

      private

      def repush(job, queue)
        payload = Wurk.dump_json(job)
        redis_pool.with { |conn| conn.call('LPUSH', "queue:#{queue}", payload) }
      end
    end
  end
end

Wurk.configuration.server_middleware.prepend(Wurk::Middleware::InterruptHandler)
