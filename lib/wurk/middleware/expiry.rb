# frozen_string_literal: true

require_relative '../job'
require_relative '../middleware'
require_relative '../metrics/statsd'
require_relative '../processor'

module Wurk
  module Middleware
    # Server middleware. Drops a job whose window has closed before `perform`
    # gets a chance to start. Two options open such a window, both stamped onto
    # the payload as an absolute epoch-float at push (JobUtil#finalize), and the
    # earlier of the two is the one that counts:
    #
    #   * `expiry`, from Pro's `sidekiq_options expires_in:`. Once `perform` is
    #     invoked it no longer preempts — a long-running job that started in
    #     time finishes.
    #   * `deadline_at`, from `sidekiq_options deadline:`. This one does preempt:
    #     {Timeout} arms the watchdog with whatever is left of it, and the
    #     {Wurk::Job::DeadlineExceeded} that lands in a job still running past
    #     its cutoff unwinds to here, where it takes the same skip path. So a
    #     deadline reaches the same terminal state whether it passed while the
    #     job queued or while it ran — one state to reason about, one counter to
    #     watch, and no retry either way.
    #
    # The skip path:
    #   * bumps Wurk::Processor::EXPIRED so the heartbeat flushes
    #     `stat:expired` + `stat:expired:YYYY-MM-DD` to Redis, surfacing the
    #     count in Wurk::Stats and the dashboard
    #   * emits `jobs.expired` via Wurk::Metrics::Statsd (no-op when no client
    #     is configured)
    #   * returns without yielding — no exception, so JobRetry treats it as a
    #     clean exit and the processor acks the UoW
    #   * counts as a batch success: because this middleware is registered
    #     AFTER `Wurk::Batch::ServerMiddleware`, returning unwinds back through
    #     batch's `yield`, and batch's `ack_success` still runs on the way out
    #
    # The expired job is *also* counted toward PROCESSED — Processor#stats's
    # ensure block always increments PROCESSED, so EXPIRED is an additive
    # subset (executed = processed - failed - expired). Matches Sidekiq Pro.
    #
    # Spec: docs/target/sidekiq-pro.md §7.
    class Expiry
      include Wurk::Middleware::ServerMiddleware

      def call(_job_instance, job, _queue)
        expiry = job['expiry']
        deadline = job['deadline_at']
        return yield unless expiry || deadline

        return drop(job) if ::Time.now.to_f > cutoff(expiry, deadline)

        yield
      rescue ::Wurk::Job::DeadlineExceeded
        drop(job)
      end

      private

      # Whichever window closes first. Coerced rather than type-checked, so a
      # payload that round-tripped a timestamp as a String still expires.
      def cutoff(expiry, deadline)
        return deadline.to_f unless expiry
        return expiry.to_f unless deadline

        [expiry.to_f, deadline.to_f].min
      end

      # nil, never a raise — the skip path above, and the reason nothing
      # schedules another attempt at a job whose window has already closed.
      def drop(job)
        Wurk::Processor::EXPIRED.incr
        Wurk::Metrics::Statsd.increment('jobs.expired', tags: ["class:#{job['class']}"])
        nil
      end
    end
  end
end

Wurk.configuration.server_middleware.add(Wurk::Middleware::Expiry)
