# frozen_string_literal: true

module Wurk
  class Web
    # Web UI configuration. Holds the authorization callback documented in
    # docs/target/sidekiq-ent.md §9.2 — a Rack-level hook called with
    # `(env, method, path)` per request. Truthy return proceeds; falsey
    # short-circuits to 403.
    #
    # Wurk ships the Ent feature in the free gem. No license check; the
    # block runs unconditionally when present.
    #
    # Example:
    #
    #   Wurk::Web.configure do |c|
    #     c.authorization do |env, method, _path|
    #       user = env['warden']&.user
    #       method == 'GET' ? user&.support? || user&.admin? : user&.admin?
    #     end
    #   end
    #
    # When no block is registered, every request is authorized (matches
    # Sidekiq's default — no auth until the user opts in).
    class Config
      # String forms that mean "off" — so `config.web.read_only = ENV[...]`
      # doesn't flip on when the env var is "0"/"false"/empty.
      FALSEY_STRINGS = ['', '0', 'false', 'no', 'off'].freeze

      # Host-app Rack middleware stacked in front of the dashboard, newest
      # last. Each entry is `[middleware, args, block]`. Returns a frozen copy
      # so the memoized chain (`#rack_app`) can only be invalidated through
      # `#use` — direct mutation can't silently desync it.
      def middlewares
        @middlewares.dup.freeze
      end

      def initialize
        @authorization = nil
        @read_only = env_read_only?
        @read_only_message = nil
        @middlewares = []
        @rack_app = nil
      end

      # Optional banner copy shown by the dashboard in read-only mode. Nil →
      # the SPA falls back to its localized default ("Read-only mode"). Lets a
      # host explain *why* it's read-only — e.g. the public demo sets
      # "This is a public demo — actions are disabled."
      attr_accessor :read_only_message

      # Registers a `(env, method, path) -> truthy/falsey` block. Re-calling
      # overwrites; the spec exposes a single hook, not a chain.
      def authorization(&block)
        @authorization = block if block
        @authorization
      end

      # Sidekiq-compatible (`Sidekiq::Web.use`). Registers a Rack middleware
      # that wraps the dashboard, in front of the authorization hook, so a
      # host app can gate the UI with Devise/Warden/Sorcery/Rack::Auth::Basic
      # without writing its own middleware. `args` and an optional block pass
      # straight through to the middleware's `new`. Call before the first
      # request (i.e. from an initializer) — the chain is built once.
      def use(middleware, *args, &block)
        @middlewares << [middleware, args, block]
        @rack_app = nil
      end

      # Builds (once) the host-middleware chain wrapping `inner` and memoizes
      # it on this Config. `reset_config!` swaps in a fresh Config, so each
      # test rebuilds cleanly; production builds exactly once at boot.
      def rack_app(inner)
        @rack_app ||= begin
          stack = @middlewares
          ::Rack::Builder.new do
            stack.each { |middleware, args, block| use(middleware, *args, &block) }
            run inner
          end.to_app
        end
      end

      # Read-only mode. When on, the Authorization middleware blocks every
      # non-GET request (retry/kill/requeue/delete/pause/resume/clear) with
      # 403, and the SPA hides destructive actions via the /api/meta flag.
      # Defaults from WURK_WEB_READ_ONLY=1 so a viewer-only deploy (e.g. the
      # public demo) needs no Ruby config.
      def read_only=(value)
        @read_only = value.is_a?(String) ? !FALSEY_STRINGS.include?(value.strip.downcase) : !!value
      end

      def read_only?
        @read_only
      end

      def reset!
        @authorization = nil
        @read_only = env_read_only?
        @read_only_message = nil
        @middlewares = []
        @rack_app = nil
      end

      # Returns true when no block is registered, otherwise the block's
      # truthiness. The `path` argument is the engine-relative path so a
      # consumer mounting under `/wurk` sees `/api/stats`, not the host's
      # absolute path — that matches Sidekiq's contract.
      def authorized?(env, method, path)
        return true if @authorization.nil?

        !!@authorization.call(env, method, path)
      end

      private

      def env_read_only?
        ENV['WURK_WEB_READ_ONLY'] == '1'
      end
    end

    class << self
      def config
        @config ||= Config.new
      end

      def configure
        yield config
      end

      # Class-level shorthand for `config.use` — mirrors `Sidekiq::Web.use`.
      def use(...)
        config.use(...)
      end

      # Test helper — exposed for parity with `Wurk::Limiter.reset_config!`.
      # Production callers should not need to drop the auth block at runtime.
      def reset_config!
        @config = nil
      end
    end

    # Rack middleware inserted into the engine. Resolves PATH_INFO + REQUEST_METHOD
    # from `env` and delegates to `Wurk::Web.config`. The engine's mount path
    # is stripped via `SCRIPT_NAME` so the callback sees engine-relative paths.
    class Authorization
      FORBIDDEN_BODY = 'Forbidden'
      READ_ONLY_BODY = 'Read-only mode'
      FORBIDDEN_HEADERS = { 'Content-Type' => 'text/plain' }.freeze
      # Methods allowed while read-only. Anything else is a mutation and 403s.
      SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        method = env['REQUEST_METHOD']
        path = env['PATH_INFO'].to_s
        config = Wurk::Web.config
        return forbidden(FORBIDDEN_BODY) unless config.authorized?(env, method, path)
        return forbidden(READ_ONLY_BODY) if config.read_only? && !SAFE_METHODS.include?(method)

        @app.call(env)
      end

      private

      def forbidden(body)
        [403, FORBIDDEN_HEADERS.dup, [body]]
      end
    end

    # Engine Rack middleware that applies the host-registered `Wurk::Web.use`
    # chain (Devise/Warden/Sorcery/Rack::Auth::Basic) in front of the
    # dashboard. Inserted ahead of `Authorization` so host auth runs first and
    # its `env` (e.g. `env['warden']`) is visible to the authorization hook.
    # The chain is built lazily on first request — after host initializers
    # have run — then memoized on the Config.
    class MiddlewareStack
      def initialize(app)
        @app = app
      end

      def call(env)
        Wurk::Web.config.rack_app(@app).call(env)
      end
    end
  end
end
