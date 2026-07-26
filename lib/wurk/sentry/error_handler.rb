# frozen_string_literal: true

require_relative '../configuration'

module Wurk
  module Sentry
    # `config.error_handlers` entry: reports the failures that never become a
    # job failure — fetch-loop errors (`context: "Error fetching job"`),
    # shutdown-path errors (`"!shutdown"`), unparseable payloads
    # (`"Invalid JSON"`), and the retry machinery's own meta-errors (a raising
    # `sidekiq_retry_in` / `sidekiq_retries_exhausted` block, a raising death
    # handler). {Middleware} covers job failures; these are the rest.
    #
    # Handler signature is Sidekiq's: `call(exception, context_hash, config)`.
    class ErrorHandler
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

      def call(exception, context = {}, _config = nil)
        return nil unless Wurk::Sentry.enabled?
        return nil if exception.is_a?(Wurk::Shutdown)
        return nil if filtered?(exception)

        ::Sentry.capture_exception(exception, extra: extra_for(context), tags: tags_for(context))
        nil
      end

      def filtered?(exception)
        return false unless @filter_transport_errors

        @filtered_error_classes.any? { |klass| exception.is_a?(klass) }
      end

      private

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
