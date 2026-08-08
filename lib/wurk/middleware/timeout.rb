# frozen_string_literal: true

require_relative '../middleware'
require_relative '../job'

module Wurk
  module Middleware
    # Puts `sidekiq_options timeout: <seconds>` of wall clock on one attempt.
    # Past it the capsule's {Wurk::Watchdog} raises {Wurk::Job::TimedOut} into
    # the thread running `perform`, and the job takes the ordinary failure path
    # from there: booked as a failure, retried on the class's own policy, dead
    # set once the retries run out. A class without `timeout:` — the default —
    # costs one Hash lookup and a `yield`.
    #
    # Per attempt, not per job: every attempt re-arms its own bound, so a retry
    # of a job that timed out gets the full budget again.
    #
    # Soft only. `Thread#kill` would cut the job between any two instructions,
    # stranding whatever it was holding — a checked-out connection, a half
    # written file, a lock nobody is left to release. That is the class of bug
    # docs/plans/2026/07/31/101-leak-logic-perf-fixes/ closed, and the reason a
    # hard kill belongs to the process supervisor rather than to a thread. What
    # soft costs is that a `perform` which swallows StandardError swallows this
    # too: the same bargain Celery's soft time limit and stdlib `Timeout` make.
    #
    # Chain position (lib/wurk.rb), both halves load-bearing:
    #   * OUTSIDE Statsd / History / Status, so the raise unwinds *through* all
    #     three and the timeout is measured and booked as the failure it is.
    #   * INSIDE Batch, Expiry and Limiter. Limiter is the sharp one: its rescue
    #     re-enqueues an over-limit job and only then raises `Rescheduled`, so a
    #     bound reaching around it could fire between those two steps and leave
    #     the job both rescheduled and retried. Ending the bound before that
    #     frame puts the bookkeeping out of the watchdog's reach.
    #
    # Against `shutdown_timeout`: both bounds run and the shorter one wins. A
    # `timeout` under the drain budget fires first and the job retries; over it,
    # shutdown unwinds the job with `Wurk::Shutdown` instead and the payload is
    # reclaimed from the private list on the next boot.
    class Timeout
      include Wurk::Middleware::ServerMiddleware

      # The block is passed on rather than taken as `&block`: reifying it would
      # allocate a Proc for every job in the process, bounded or not.
      def call(_worker, job, _queue)
        seconds = bound_for(job)
        timer = seconds && watchdog
        return yield unless timer

        timer.watch(seconds, ::Wurk::Job::TimedOut, message_for(job, seconds)) { yield } # rubocop:disable Style/ExplicitBlockArgument
      end

      private

      # A `timeout` written through Wurk is type-checked at declaration, where
      # the author can be told about it. This is the other door: a payload from
      # stock Sidekiq, a raw LPUSH, or a release older than the option never
      # passed that check, and a bound we can't use on one of those has to leave
      # the job unbounded rather than break it.
      def bound_for(job)
        seconds = job['timeout']
        return unless seconds.is_a?(::Numeric) && seconds.positive? && seconds.finite?

        seconds
      end

      # The watchdog belongs to the Capsule, which builds it in `prepare!`.
      # Nothing else that invokes a server chain has one — a Configuration-bound
      # chain, `Wurk::Testing.inline!`, a chain driven straight from a test — and
      # those run the job unbounded: the bound is a safety net, and a harness
      # that never built a capsule is not the place to fail a job over it.
      def watchdog
        config.watchdog if config.respond_to?(:watchdog)
      end

      # What an operator reads in the retry set, the dead set, and their error
      # tracker, so it names both the class and the bound it broke.
      def message_for(job, seconds)
        "#{job['class']} timed out after #{seconds}s"
      end
    end
  end
end

Wurk.configuration.server_middleware.add(Wurk::Middleware::Timeout)
