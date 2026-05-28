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

      def initialize
        @authorization = nil
        @read_only = env_read_only?
      end

      # Registers a `(env, method, path) -> truthy/falsey` block. Re-calling
      # overwrites; the spec exposes a single hook, not a chain.
      def authorization(&block)
        @authorization = block if block
        @authorization
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
  end
end
