# frozen_string_literal: true

require_relative '../wurk'
require_relative 'sentry/error_handler'
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
    class << self
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
      # @return [Wurk::Configuration] the config, for chaining.
      def install!(config = Wurk.configuration, filter_transport_errors: true, filtered_error_classes: nil)
        config.server_middleware.add(Middleware)
        install_error_handler(config, filter_transport_errors, filtered_error_classes)
        config
      end

      # True only when sentry-ruby is loaded *and* `Sentry.init` has run.
      # Guards every call into the SDK so the integration is inert by default.
      def enabled?
        defined?(::Sentry) && ::Sentry.respond_to?(:initialized?) && ::Sentry.initialized?
      end

      private

      def install_error_handler(config, filter, classes)
        handlers = config.error_handlers
        handlers.reject! { |handler| handler.is_a?(ErrorHandler) }
        handlers << ErrorHandler.new(
          filter_transport_errors: filter,
          filtered_error_classes: classes
        )
      end
    end
  end
end
