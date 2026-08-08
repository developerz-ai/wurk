# frozen_string_literal: true

require_relative '../middleware'

module Wurk
  module Telemetry
    # Producer half of the pair: a `<queue> publish` span around the rest of the
    # enqueue, with that span's W3C trace context written onto the job hash so
    # the worker that eventually runs the job can tie its own span back to
    # whoever pushed it. Injection happens once per payload, which means every
    # `push_bulk` item gets its own context — the chain runs per item there
    # (Client#build_bulk_payloads), not once for the slice.
    #
    # Registered only by {Wurk::Telemetry.install!}, i.e. only once the host
    # opted in *and* opentelemetry-api is loaded. An app that did neither has no
    # entry in the chain at all — no span, and not one extra byte on the wire.
    #
    # Tail position (`add`) is deliberate on both counts: a middleware that
    # halts the push — a uniqueness gem dropping a duplicate — runs *outside*
    # this one, so no publish span is opened for a job that was never published;
    # and nothing downstream of the injection can strip the key back off.
    class ClientMiddleware
      include Wurk::Middleware::ClientMiddleware

      def call(_worker, job, queue, _redis_pool)
        Telemetry.tracer.in_span("#{queue} publish", attributes: attributes(job, queue), kind: :producer) do
          # Inside the span so the context written is the producer span's own,
          # which is what the consumer end links back to.
          #
          # The propagator writes `traceparent`, plus `tracestate` only when the
          # trace actually carries vendor state — top-level String values, so
          # this adds nothing to the args tree `verify_json` walks one frame in
          # (bulk verifies inside this very block; see
          # Client#invoke_chain_verified). The single-walk-per-push property
          # holds unchanged: this middleware never verifies.
          ::OpenTelemetry.propagation.inject(job)
          yield
        end
      end

      private

      # `messaging.*` names are the OTel messaging semantic conventions. The job
      # class has no conventional name, so it takes the `messaging.<system>.*`
      # extension slot those conventions reserve — where
      # opentelemetry-instrumentation-sidekiq puts it too. `wrapped` is the real
      # class behind an ActiveJob wrapper; without it every AJ span would read
      # as the one adapter class.
      def attributes(job, queue)
        {
          'messaging.system' => 'wurk',
          'messaging.destination.name' => queue,
          'messaging.message.id' => job['jid'],
          'messaging.wurk.job_class' => job['wrapped'] || job['class']
        }
      end
    end
  end
end
