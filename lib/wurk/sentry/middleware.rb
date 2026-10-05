# frozen_string_literal: true

require_relative '../middleware'
require_relative '../job_retry'
require_relative 'error_handler'
require_relative 'job_context'
require_relative 'retry_policy'

module Wurk
  module Sentry
    # Server middleware: scopes every job for Sentry, and reports the job's
    # terminal failure while that scope is still open.
    #
    # The same failure then reaches `config.error_handlers` as
    # `"Job raised exception"`; the middleware marks every exception it saw
    # (captured or not) so {ErrorHandler} leaves it alone and reports only the
    # job failures that never passed through here.
    #
    # The exception is always re-raised: Wurk's retry pipeline, not this
    # middleware, owns the failure.
    class Middleware
      include Wurk::Middleware::ServerMiddleware

      def call(instance, job, queue, &block)
        return yield unless Wurk::Sentry.enabled?

        # Each Processor owns a thread, and Sentry's hub is thread-local.
        # Without this the worker thread starts from an empty hub and the
        # scope set below is invisible to the capture.
        ::Sentry.clone_hub_to_current_thread

        ::Sentry.with_scope do |scope|
          JobContext.apply(scope, job, queue)
          monitor(instance, job, &block)
        end
      end

      private

      def monitor(instance, job)
        yield
      rescue Wurk::JobRetry::Handled, Wurk::Shutdown
        # Handled/Skip: an inner middleware already booked the outcome (the
        # limiter re-enqueued, the interrupt handler re-pushed). Shutdown: the
        # job is requeued and will run again — a deploy is not a failure.
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        raise if caused_by_shutdown?(e)

        ErrorHandler.seen_by_middleware!(e)
        ::Sentry.capture_exception(e) if RetryPolicy.terminal?(job, instance, config)
        raise
      end

      # Mirrors `JobRetry#exception_caused_by_shutdown?`: user code that
      # rescued `Wurk::Shutdown` and re-raised something else is still a
      # shutdown, not a job failure.
      def caused_by_shutdown?(exception, checked = [])
        cause = exception.cause
        return false unless cause

        checked << exception.object_id
        return false if checked.include?(cause.object_id)

        cause.instance_of?(Wurk::Shutdown) || caused_by_shutdown?(cause, checked)
      end
    end
  end
end
