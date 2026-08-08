# frozen_string_literal: true

require_relative '../middleware'
require_relative '../job'
require_relative '../job_retry'

module Wurk
  module Telemetry
    # Consumer half of the pair: a `<klass> process` span around the rest of the
    # server chain and `perform`, tied back to the producer span whose W3C trace
    # context {ClientMiddleware} wrote onto the job hash.
    #
    # Registered only by {Wurk::Telemetry.install!} — gem present *and* host
    # opted in — one position inside `Middleware::InterruptHandler`, so the span
    # covers every other middleware (limiter, batch, metrics, status) and the
    # job body, and its duration is the job's real wall clock rather than
    # `perform`'s alone. Inside rather than outside the interrupt handler
    # because that handler's rescue is what turns a cooperative stop into a
    # re-push plus `JobRetry::Skip`: from outside, the span would also be
    # wrapping a Redis RPUSH that is not part of running the job.
    #
    # A job with no `traceparent` — pushed by stock Sidekiq, by a Wurk process
    # with tracing off, or straight into Redis by hand — still gets a span. It
    # is simply a root, with nothing to point at.
    class ServerMiddleware
      include Wurk::Middleware::ServerMiddleware

      # How stale a producer context may be and still be used as the span's
      # *parent* rather than as a link.
      #
      # Under this, enqueue and execute are one causal step and the pair belongs
      # in one trace: the parent edge is what OTel's messaging conventions ask
      # for, and it is what makes "show me this request" include the work it
      # queued. Past it, the job is a scheduled one, a cron tick, or a retry
      # backoff — the producer's trace was exported, sampled and closed minutes
      # to hours ago, and hanging a new span off it yields a trace the backend
      # will split, drop, or hold open for a day. So past the window the
      # relationship is recorded as a span **link**: same information, no
      # unbounded trace.
      #
      # 60s is chosen to sit above normal enqueue→execute latency on a healthy
      # queue (sub-second) and below the decision window of the tail samplers
      # that would otherwise have already ruled on the producer's trace.
      PARENT_WINDOW_SECONDS = 60

      # `created_at` is epoch millis today — `JobUtil#now_in_millis`, and
      # upstream's own since Sidekiq 8.x — but Sidekiq <= 7.x stamped a Float of
      # epoch *seconds*, and those payloads outlive the upgrade in the retry,
      # scheduled and dead sets. Read shape-agnostically on the same threshold
      # `JobRecord#parse_time` and `Stats` use: no epoch-second stamp reaches
      # ten digits until 2286, and no epoch-milli one has been under it since
      # April 1970. Assuming millis would date every seconds-shaped job to 1970
      # and demote a perfectly fresh one from parent to link.
      SECONDS_SHAPED_BELOW = 10_000_000_000

      # Retries carry the *original* `traceparent`: `JobRetry#schedule_retry`
      # re-ZADDs the same hash, so the client chain — and with it injection —
      # never runs again. That is deliberate and it is the answer to "one trace
      # per logical job vs. a fresh root per attempt": every attempt is
      # reachable from the enqueue that caused it. Attempt 1 usually lands
      # inside the window and is a child; later attempts, pushed out by
      # exponential backoff, land outside it and are roots carrying a link back.
      # Neither is ever an unrelated root.
      def call(_worker, job, queue)
        span = start(job, queue)
        # `yield` rather than taking the chain's block as `&block`: capturing it
        # allocates a Proc for every job in the process, and this frame runs on
        # every one of them.
        ::OpenTelemetry::Trace.with_span(span) { yield } # rubocop:disable Style/ExplicitBlockArgument
      rescue Wurk::JobRetry::Handled, Wurk::Job::Interrupted
        # The canonical not-an-error list (see Batch::ServerMiddleware): a
        # cooperative interruption, and every `Handled` — which is where
        # `JobRetry::Skip` and, under it, `Limiter::Rescheduled` live. None of
        # them is a job that went wrong; each is one that was put back and will
        # run again. Marking the span an error would paint a rate-limited or
        # gracefully-paused deploy as an outage.
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Everything else that unwinds through here, `Wurk::Shutdown` included:
        # a job killed by a hard shutdown did not complete, and that is exactly
        # the signal an operator tuning `shutdown_timeout` is looking for.
        span&.record_exception(e)
        span&.status = ::OpenTelemetry::Trace::Status.error("Unhandled exception of type: #{e.class}")
        raise
      ensure
        span&.finish
      end

      private

      # Hand-rolled rather than `tracer.in_span`: that helper rescues
      # `Exception` and unconditionally stamps an error status, which would cost
      # us the taxonomy above — its `record_exception:` kwarg suppresses the
      # event but not the status.
      def start(job, queue)
        context  = ::OpenTelemetry.propagation.extract(job)
        producer = ::OpenTelemetry::Trace.current_span(context).context
        name     = "#{job_class(job)} process"
        common   = { attributes: attributes(job, queue), kind: :consumer }

        return Telemetry.tracer.start_span(name, with_parent: context, **common) if parent?(producer, job)

        Telemetry.tracer.start_root_span(name, links: link_to(producer), **common)
      end

      # Unknown age resolves to a link, not a parent. The two mistakes are not
      # symmetric: a link where a parent belonged costs one hop in the UI, while
      # a parent where a link belonged can stretch a trace across hours and lose
      # it entirely.
      def parent?(producer, job)
        return false unless producer.valid?

        age = age_of(job)
        !age.nil? && age < PARENT_WINDOW_SECONDS
      end

      # nil, not [], when there is nothing to point at — `links: nil` is the
      # API's own "no links" and keeps a span from carrying an empty array.
      def link_to(producer)
        [::OpenTelemetry::Trace::Link.new(producer)] if producer.valid?
      end

      # Age of the *trace context*, not of the enqueue: `created_at` is stamped
      # at push, which is when the producer span ended. `enqueued_at` would be
      # wrong here — the scheduler re-stamps it when it moves a job onto the
      # queue, so every scheduled job would look fresh no matter how long it
      # waited.
      def age_of(job)
        created = job['created_at']
        return nil if created.nil?

        created = created.to_f
        seconds = created < SECONDS_SHAPED_BELOW ? created : created / 1000.0
        ::Process.clock_gettime(::Process::CLOCK_REALTIME) - seconds
      end

      # Same `messaging.*` vocabulary as the producer half, so one query spans
      # both ends of the hop. `queue` is the argument rather than `job['queue']`
      # because it is the queue this job was actually consumed from.
      def attributes(job, queue)
        {
          'messaging.system' => 'wurk',
          'messaging.destination.name' => queue,
          'messaging.message.id' => job['jid'],
          'messaging.wurk.job_class' => job_class(job)
        }
      end

      def job_class(job) = job['wrapped'] || job['class']
    end
  end
end
