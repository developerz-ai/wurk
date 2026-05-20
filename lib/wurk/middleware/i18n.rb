# frozen_string_literal: true

require_relative '../middleware'

module Wurk
  module Middleware
    # Propagates `I18n.locale` from the enqueueing process to the worker.
    # Auto-registered when this file is required: Client onto the
    # `client_middleware` chain, Server onto `server_middleware`.
    #
    # No-op when the `I18n` constant is undefined (no `i18n` gem loaded);
    # the middleware survives the absence and just passes the job through.
    #
    # Job hash key: `"locale"` (matches Sidekiq spec §2.2).
    module I18n
      class << self
        def current_locale
          ::I18n.locale.to_s if defined?(::I18n)
        end

        def with_locale(locale)
          return yield unless defined?(::I18n) && locale

          previous = ::I18n.locale
          ::I18n.locale = locale
          begin
            yield
          ensure
            ::I18n.locale = previous
          end
        end
      end

      # Client: writes the current locale into the outgoing job hash before
      # push. Idempotent — a caller-supplied `"locale"` is preserved.
      # No-op when I18n isn't loaded (don't introduce a nil `"locale"` key:
      # adding it would change the wire shape for callers without I18n).
      class Client
        include Wurk::Middleware::ClientMiddleware

        def call(_job_class, job, _queue, _redis_pool)
          current = I18n.current_locale
          job['locale'] ||= current if current
          yield
        end
      end

      # Server: scopes the job execution to the captured locale. Restores
      # the previous value on the way out so middleware stacking doesn't
      # leak across jobs in the same thread.
      class Server
        include Wurk::Middleware::ServerMiddleware

        def call(_job_instance, job, _queue, &)
          I18n.with_locale(job['locale'], &)
        end
      end
    end
  end
end

Wurk.configuration.client_middleware.add(Wurk::Middleware::I18n::Client)
Wurk.configuration.server_middleware.add(Wurk::Middleware::I18n::Server)
