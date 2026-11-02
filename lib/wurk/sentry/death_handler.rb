# frozen_string_literal: true

require_relative 'error_handler'
require_relative 'job_context'

module Wurk
  module Sentry
    # Reports the deaths that never crossed the terminal-attempt path: a
    # poison-pill kill (the reaper kills the job from outside, nothing raised)
    # and a `sidekiq_retry_in` block answering `:kill` or `:discard` early.
    #
    # A job that died the ordinary way was captured moments ago on this same
    # thread, so that exception is skipped. An operator's kill carries no
    # exception and is not a fault.
    class DeathHandler
      def call(job, exception = nil)
        return unless exception && Wurk::Sentry.enabled?
        return if ErrorHandler.reported?(exception)

        job = {} unless job.is_a?(::Hash)
        ::Sentry.with_scope do |scope|
          JobContext.apply(scope, job, job['queue'])
          ::Sentry.capture_exception(exception, tags: { wurk_context: 'dead' })
        end
        ErrorHandler.reported!(exception)
      end
    end
  end
end
