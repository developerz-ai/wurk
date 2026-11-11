# frozen_string_literal: true

require_relative '../wurk'
require_relative 'sentry/error_handler'
require_relative 'sentry/death_handler'
require_relative 'sentry/middleware'

module Wurk
  # Opt-in Sentry integration. Not loaded by `require "wurk"` — pull it in
  # explicitly and install it on the server config:
  #
  #   # config/initializers/wurk.rb
  #   require "wurk/sentry"
  #
  #   Wurk.configure_server do |config|
  #     Wurk::Sentry.install!(config)
  #   end
  #
  # This exists because `sentry-sidekiq` **cannot be used with Wurk**: its
  # gemspec declares `add_dependency "sidekiq"`, so Bundler installs real
  # Sidekiq alongside Wurk and `require "sidekiq"` loads a broken hybrid.
  # (The `ecosystem/sidekiq-shim/` git source is the escape hatch for gems
  # you must keep; see docs/sentry.md.)
  #
  # `sentry-ruby` is **not** a runtime dependency — it is never required here,
  # and every call site is guarded by {enabled?}. Loading this file in an app
  # without sentry-ruby, or before `Sentry.init` has run, is a no-op.
  #
  # See docs/sentry.md.
  module Sentry
    # Sentry matches an excluded name by ancestry, so Handled also covers
    # `JobRetry::Skip`, its subclass.
    CONTROL_FLOW_ERRORS = %w[Wurk::JobRetry::Handled Wurk::Shutdown].freeze

    class << self
      # The retry machinery's own signals, for a Sentry setup that does not run
      # {install!} (the web process, a `Sentry.init` that runs first):
      #
      #   config.excluded_exceptions += Wurk::Sentry.excluded_exceptions
      #
      # A `Rails.error` subscriber sees these cross the reloader on every failed
      # attempt, as it does under Sidekiq.
      def excluded_exceptions = CONTROL_FLOW_ERRORS

      # Registers the server middleware and the error handler. Idempotent:
      # `Chain#add` dedupes by class, and a previously-installed
      # {ErrorHandler} is replaced rather than stacked, so calling this twice
      # (or calling it after an auto-install) never doubles a report.
      #
      # @param config [Wurk::Configuration] usually the block argument of
      #   `Wurk.configure_server`.
      # @param filter_transport_errors [Boolean] drop self-healing Redis /
      #   connection-pool errors instead of reporting them. See
      #   {ErrorHandler::DEFAULT_FILTERED_ERROR_CLASSES}.
      # @param filtered_error_classes [Array<Class>, nil] replaces the default
      #   filter list. Extend it with
      #   `Wurk::Sentry::ErrorHandler::DEFAULT_FILTERED_ERROR_CLASSES + [MyError]`.
      # @param report_after_attempts [Integer, nil] also report the failure of
      #   this attempt (1 is the first run), on top of the terminal one. By
      #   default a job on the 25-retry schedule first alerts ~21 days in.
      # @return [Wurk::Configuration] the config, for chaining.
      def install!(config = Wurk.configuration, filter_transport_errors: true, filtered_error_classes: nil,
                   report_after_attempts: nil)
        validate_attempts!(report_after_attempts)
        config.server_middleware.add(Middleware, report_after_attempts)
        install_error_handler(config, filter_transport_errors, filtered_error_classes, report_after_attempts)
        install_death_handler(config)
        exclude_control_flow_errors
        config
      end

      # True only when sentry-ruby is loaded *and* `Sentry.init` has run.
      # Guards every call into the SDK so the integration is inert by default.
      def enabled?
        defined?(::Sentry) && ::Sentry.respond_to?(:initialized?) && ::Sentry.initialized?
      end

      private

      def validate_attempts!(attempts)
        return if attempts.nil? || (attempts.is_a?(::Integer) && attempts.positive?)

        raise ::ArgumentError, "report_after_attempts must be nil or a positive Integer (got #{attempts.inspect})"
      end

      def install_error_handler(config, filter, classes, attempts)
        handlers = config.error_handlers
        handlers.reject! { |handler| handler.is_a?(ErrorHandler) }
        handlers << ErrorHandler.new(
          filter_transport_errors: filter,
          filtered_error_classes: classes,
          report_after_attempts: attempts
        )
      end

      def install_death_handler(config)
        handlers = config.death_handlers
        handlers.reject! { |handler| handler.is_a?(DeathHandler) }
        handlers << DeathHandler.new
      end

      # A subscriber on `Rails.error` (sentry-rails) captures whatever crosses
      # the reloader, including the retry machinery's signals, without passing
      # through the handler above. `Sentry.init` builds a new Configuration, so
      # before it has run the only place to reach that one is its init hook.
      def exclude_control_flow_errors
        names = CONTROL_FLOW_ERRORS
        if enabled? && ::Sentry.respond_to?(:configuration)
          sdk_config = ::Sentry.configuration
          sdk_config.excluded_exceptions |= names
        elsif defined?(::Sentry::Configuration) && ::Sentry::Configuration.respond_to?(:after)
          ::Sentry::Configuration.after(:initialize) { self.excluded_exceptions |= names }
        end
      end
    end
  end
end
