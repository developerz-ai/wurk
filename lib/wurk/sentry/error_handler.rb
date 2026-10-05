# frozen_string_literal: true

require_relative '../configuration'
require_relative 'job_context'
require_relative 'retry_policy'

module Wurk
  module Sentry
    # `config.error_handlers` entry. Reports fetch-loop errors
    # (`context: "Error fetching job"`), shutdown-path errors (`"!shutdown"`),
    # unparseable payloads (`"Invalid JSON"`), the retry machinery's own
    # meta-errors, and job failures (`"Job raised exception"`).
    #
    # A job failure is {Middleware}'s to report whenever the exception passed
    # through it: the middleware holds the job's scope and has already applied
    # the terminal-attempt policy, so reporting it here too would double it.
    # What reaches this handler unseen raised outside the middleware — the
    # class failed to load, the reloader or an earlier middleware raised — and
    # gets the same policy and scope here.
    #
    # Handler signature is Sidekiq's: `call(exception, context_hash, config)`.
    class ErrorHandler
      JOB_FAILURE = 'Job raised exception'

      # Thread-local handshake with {Middleware}: the exception it last saw on
      # this thread. Error handlers run synchronously on the processor thread
      # that raised, so the slot is never read across threads.
      SEEN_BY_MIDDLEWARE = :wurk_sentry_seen_by_middleware

      def self.seen_by_middleware!(exception)
        Thread.current[SEEN_BY_MIDDLEWARE] = exception
      end

      # Transport blips the pool already retried before re-raising. Wurk's
      # default handler logs these at WARN precisely because they are
      # self-healing (`Configuration::REDIS_ERROR_CLASSES`), and the fetch loop
      # runs them in a tight `sleep(1)` cycle: on one production Dragonfly
      # backend a single Sentry issue accumulated ~136,000 events from fetch
      # blips while the job pipeline was completely healthy. They stay in the
      # logs; they just stop paging anyone.
      DEFAULT_FILTERED_ERROR_CLASSES = Wurk::Configuration::REDIS_ERROR_CLASSES

      attr_reader :filtered_error_classes

      def initialize(filter_transport_errors: true, filtered_error_classes: nil)
        @filter_transport_errors = filter_transport_errors
        @filtered_error_classes = (filtered_error_classes || DEFAULT_FILTERED_ERROR_CLASSES).to_a.freeze
      end

      def call(exception, context = {}, config = nil)
        return nil unless Wurk::Sentry.enabled?
        return nil if exception.is_a?(Wurk::Shutdown)
        # Ahead of the transport filter: that filter quiets the infrastructure
        # loop, and a job that died on a Redis error is still a dead job.
        return capture_job_failure(exception, context, config) if job_failure?(context)
        return nil if filtered?(exception)

        ::Sentry.capture_exception(exception, extra: extra_for(context), tags: tags_for(context))
        nil
      end

      def filtered?(exception)
        return false unless @filter_transport_errors

        @filtered_error_classes.any? { |klass| exception.is_a?(klass) }
      end

      private

      def job_failure?(context)
        context.is_a?(::Hash) && context[:context] == JOB_FAILURE && context[:job].is_a?(::Hash)
      end

      def capture_job_failure(exception, context, config)
        return nil if claimed_by_middleware?(exception)

        job = context[:job]
        return nil unless RetryPolicy.terminal?(job, nil, config)

        ::Sentry.with_scope do |scope|
          JobContext.apply(scope, job, job['queue'])
          ::Sentry.capture_exception(exception, extra: extra_for(context), tags: tags_for(context))
        end
        nil
      end

      def claimed_by_middleware?(exception)
        seen = Thread.current[SEEN_BY_MIDDLEWARE]
        return false unless seen.equal?(exception)

        Thread.current[SEEN_BY_MIDDLEWARE] = nil
        true
      end

      # Same rule as {JobContext}: job arguments never reach Sentry. `jobstr`
      # (the raw payload of an unparseable job) is dropped wholesale — it *is*
      # the args, unparsed.
      def extra_for(context)
        return {} unless context.is_a?(::Hash)

        context.each_with_object({}) do |(key, value), out|
          next if key.to_s == 'jobstr'

          out[key] = value.is_a?(::Hash) ? scrub_args(value) : value
        end
      end

      def scrub_args(hash)
        hash.reject { |key, _| key.to_s == 'args' }
      end

      # Wurk's context labels are a small fixed set, so this is a low-cardinality
      # tag you can facet the issue stream on.
      def tags_for(context)
        label = context[:context] if context.is_a?(::Hash)
        label ? { wurk_context: label } : {}
      end
    end
  end
end
