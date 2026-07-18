# frozen_string_literal: true

require_relative '../job_retry'

module Wurk
  module Limiter
    # Control signal raised after a job has been rescheduled: the limiter has
    # already re-enqueued it (via `Client.push` at `Time.now + backoff`), so
    # the run is *neither* a success nor a failure. Subclassing
    # `JobRetry::Skip` routes it through the existing "middleware re-pushed the
    # job — ack cleanly, book no retry" contract: the retrier re-raises it
    # untouched, the outer Batch middleware skips both acks (its `rescue
    # Handled` re-raises), and the Processor acks the UnitOfWork. Returning
    # normally instead would let the outer Batch onion ack success for a job
    # that never ran. Internal only — not part of the Sidekiq drop-in surface.
    class Rescheduled < Wurk::JobRetry::Skip; end

    # Catches OverLimit (and any class registered in `Limiter.config.errors`),
    # bumps `job['overrated']`, and decides what to do next:
    #
    #   * reschedule disabled (`reschedule: 0`) → re-raise so the normal
    #     retry/dead pipeline handles it (spec §1.2/§1.4 behaviour).
    #   * still under the cap → reschedule onto the same queue at
    #     `Time.now + backoff` via `Client.push`, then raise `Rescheduled` so
    #     the outcome is neither success nor failure (batch onion skips acks).
    #   * cap reached (`overrated >= reschedule`, default 20) → **poison
    #     brake** (#16): a job that's still rate-limited after N reschedules
    #     is saturating the limiter, so instead of dumping it into another
    #     25× retry loop we route it straight to the dead set tagged
    #     `rate_limited`, bumping `jobs.rate_limited` and firing death
    #     handlers. Bounded: termination at exactly `reschedule` attempts.
    class ServerMiddleware
      include Wurk::Middleware::ServerMiddleware

      DEAD_REASON = 'rate_limited'

      def call(_worker, job, _queue)
        yield
      rescue StandardError => e
        raise unless over_limit?(e)

        handle_over_limit(job, e)
      end

      private

      def over_limit?(exc)
        Wurk::Limiter.config.errors.any? { |k| exc.is_a?(k) }
      end

      def handle_over_limit(job, exc)
        job['overrated'] = job.fetch('overrated', 0).to_i + 1
        limiter = exc.respond_to?(:limiter) ? exc.limiter : nil
        exc.job = job if exc.respond_to?(:job=)
        cap = reschedule_cap(limiter)

        raise exc if cap.zero? # rescheduling disabled → normal retry/dead pipeline
        return route_to_dead(job, exc) if job['overrated'] >= cap

        reschedule(job, exc, limiter)
      end

      # nil (concurrent/leaky/points never set it) → the default 20.
      def reschedule_cap(limiter)
        return DEFAULT_RESCHEDULE unless limiter

        cap = limiter.options[:reschedule]
        cap.nil? ? DEFAULT_RESCHEDULE : cap
      end

      def reschedule(job, exc, limiter)
        backoff_proc = (limiter && limiter.options[:backoff]) || Wurk::Limiter.config.backoff
        delay = backoff_proc.call(limiter, job, exc).to_f
        Wurk::Client.new.push(job.merge('at' => ::Time.now.to_f + delay))
        raise Rescheduled
      end

      # Poison brake: stamp a clear reason, drop the job in the dead set, and
      # ACK by returning normally (no re-raise) so it isn't also retried.
      def route_to_dead(job, exc)
        record = job.merge(
          'error_class' => exc.class.name,
          'error_message' => "#{DEAD_REASON}: #{exc.message} (overrated=#{job['overrated']})",
          'failed_at' => ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
        )
        Wurk::Metrics::Statsd.increment('jobs.rate_limited', tags: ["worker:#{job['class']}"])
        Wurk::DeadSet.new.kill(Wurk.dump_json(record), ex: exc)
        nil
      end
    end
  end
end
