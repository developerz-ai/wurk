# frozen_string_literal: true

require_relative '../middleware'
require_relative '../job'
require_relative '../job_util'

module Wurk
  module Middleware
    # Arms the capsule's {Wurk::Watchdog} with whichever wall-clock bounds a job
    # declared. A class that declares neither — the default — costs two Hash
    # lookups and a `yield`.
    #
    # `sidekiq_options timeout: <seconds>` bounds one attempt. Past it the
    # watchdog raises {Wurk::Job::TimedOut} into the thread running `perform`,
    # and the job takes the ordinary failure path from there: booked as a
    # failure, retried on the class's own policy, dead set once the retries run
    # out. Per attempt, not per job — every attempt re-arms its own bound, so a
    # retry of a job that timed out gets the full budget again.
    #
    # `sidekiq_options deadline: <seconds>` bounds the job from enqueue onward.
    # The client resolves it to an absolute `deadline_at` once, at push
    # (JobUtil#stamp_deadline), and what this middleware arms is whatever is
    # left of it — so retries and IterableJob resumes eat into one budget rather
    # than each getting a fresh one. Past it the watchdog raises
    # {Wurk::Job::DeadlineExceeded}, which is not a failure to retry:
    # {Expiry} catches it one frame out and books the job `expired`, the same
    # terminal state as one whose deadline had already passed before it started.
    # That check, immediately before `perform`, is the other half of the bound —
    # a job whose window closed while it queued never starts at all.
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
    #     three and the timeout is measured and booked as the failure it is. A
    #     `DeadlineExceeded` crosses the same three, which is why the two metric
    #     emitters name it: it is booked `expired`, and booking it failed as
    #     well would count one abandoned job twice.
    #   * INSIDE Batch, Expiry and Limiter. Limiter is the sharp one: its rescue
    #     re-enqueues an over-limit job and only then raises `Rescheduled`, so a
    #     bound reaching around it could fire between those two steps and leave
    #     the job both rescheduled and retried. Ending the bound before that
    #     frame puts the bookkeeping out of the watchdog's reach. Expiry has to
    #     be outside for a second reason: it is what catches the deadline raise.
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
        attempt = bound_for(job)
        remaining = deadline_for(job)
        timer = (attempt || remaining) && watchdog
        return yield unless timer

        within_deadline(timer, job, remaining) do
          within_attempt(timer, job, attempt) { yield } # rubocop:disable Style/ExplicitBlockArgument
        end
      end

      private

      # Both bounds are armed, not just whichever lands first — a job that
      # rescues its own `TimedOut` and carries on is still cut when the deadline
      # comes, which is the whole promise of an absolute bound. Which of the two
      # `watch` frames encloses the other is not load-bearing (each masks only
      # its own exception class, so both stay deliverable inside the job either
      # way); the absolute one is written outside to match the scopes they name.
      def within_deadline(timer, job, remaining)
        return yield unless remaining

        timer.watch(remaining, ::Wurk::Job::DeadlineExceeded, deadline_message(job)) { yield } # rubocop:disable Style/ExplicitBlockArgument
      end

      def within_attempt(timer, job, seconds)
        return yield unless seconds

        timer.watch(seconds, ::Wurk::Job::TimedOut, timeout_message(job, seconds)) { yield } # rubocop:disable Style/ExplicitBlockArgument
      end

      # A bound written through Wurk is type-checked at declaration, where the
      # author can be told about it. This is the other door: a payload from
      # stock Sidekiq, a raw LPUSH, or a release older than the option never
      # passed that check, and a bound we can't use on one of those has to leave
      # the job unbounded rather than break it.
      def bound_for(job)
        seconds = job['timeout']
        seconds if ::Wurk::JobUtil.positive_seconds?(seconds)
      end

      # What is left of the absolute cutoff, in seconds. Negative is not an
      # error and is armed as it comes: {Expiry} turns away everything already
      # past the cutoff one frame further out, so a bound that reaches here in
      # the past is the sliver between that check and this one — and the
      # Watchdog, unlike `Timeout.timeout`, accepts a bound that has passed.
      def deadline_for(job)
        at = job['deadline_at']
        return unless ::Wurk::JobUtil.positive_seconds?(at)

        at.to_f - ::Time.now.to_f
      end

      # The watchdog belongs to the Capsule, which builds it in `prepare!`.
      # Nothing else that invokes a server chain has one — a Configuration-bound
      # chain, `Wurk::Testing.inline!`, a chain driven straight from a test — and
      # those run the job unbounded: the bound is a safety net, and a harness
      # that never built a capsule is not the place to fail a job over it.
      def watchdog
        config.watchdog if config.respond_to?(:watchdog)
      end

      # What an operator reads in the retry set, the dead set, a tracked job's
      # status row, and their error tracker — so each names the class and the
      # bound it broke.
      def timeout_message(job, seconds)
        "#{job['class']} timed out after #{seconds}s"
      end

      def deadline_message(job)
        "#{job['class']} exceeded its deadline"
      end
    end
  end
end

Wurk.configuration.server_middleware.add(Wurk::Middleware::Timeout)
