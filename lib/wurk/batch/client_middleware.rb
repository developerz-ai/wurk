# frozen_string_literal: true

require_relative '../middleware'

module Wurk
  class Batch
    # Client middleware. When a `Job.perform_async` runs inside a
    # `batch.jobs { ... }` block, Thread.current[Batch::THREAD_KEY] holds
    # the active batch — we stamp `bid` onto the payload so the worker
    # can re-open the batch and Client#raw_push can route through
    # BATCH_PUSH for atomic increment+LPUSH.
    #
    # Auto-registered at the head of the client chain when this file is
    # required.
    class ClientMiddleware
      include Wurk::Middleware::ClientMiddleware

      def call(_worker, job, _queue, _redis_pool)
        batch = Thread.current[Batch::THREAD_KEY]
        job['bid'] = batch.bid if batch
        yield
      end
    end
  end
end

Wurk.configuration.client_middleware.prepend(Wurk::Batch::ClientMiddleware)
