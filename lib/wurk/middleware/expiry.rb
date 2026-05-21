# frozen_string_literal: true

require_relative '../middleware'
require_relative '../metrics/statsd'

module Wurk
  module Middleware
    # Server middleware. Drops jobs whose `expiry` timestamp (stamped at push
    # by the client from `sidekiq_options expires_in:`) has passed before
    # `perform` gets a chance to start. Once `perform` is invoked, expiry no
    # longer preempts — long-running jobs that started in time finish.
    #
    # The skip path:
    #   * emits `jobs.expired` via Wurk::Metrics::Statsd (no-op when no client
    #     is configured)
    #   * returns without yielding — no exception, so JobRetry treats it as a
    #     clean exit and the processor acks the UoW
    #   * counts as a batch success: because this middleware is registered
    #     AFTER `Wurk::Batch::ServerMiddleware`, returning unwinds back through
    #     batch's `yield`, and batch's `ack_success` still runs on the way out
    #
    # Spec: docs/target/sidekiq-pro.md §7.
    class Expiry
      include Wurk::Middleware::ServerMiddleware

      def call(_job_instance, job, _queue)
        expiry = job['expiry']
        return yield unless expiry

        if ::Time.now.to_f > expiry.to_f
          Wurk::Metrics::Statsd.increment('jobs.expired', tags: ["class:#{job['class']}"])
          return
        end

        yield
      end
    end
  end
end

Wurk.configuration.server_middleware.add(Wurk::Middleware::Expiry)
