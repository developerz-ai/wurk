# frozen_string_literal: true

module Wurk
  # Namespace for two unrelated things that both answer to "the API": the Pro
  # data-API Lua extensions (API::Fast, required by lib/wurk.rb at its
  # load-order-sensitive point) and the machine-facing HTTP API (API::App).
  module API
    # The one prefix the machine plane answers under, and the version it pins.
    # They live on the namespace rather than on App because the engine's mount
    # constraint has to answer "is this path mine?" on every routing pass, and
    # loading App to ask would undo the lazy load below.
    API_VERSION = 'v1'
    VERSION_PREFIX = "/#{API_VERSION}".freeze
    NESTED_PREFIX = "#{VERSION_PREFIX}/".freeze
    SUPPORTED_VERSIONS = [API_VERSION].freeze

    class << self
      # Class-level Rack entry, the same shape as Wurk::Web.call, so
      # `mount Wurk::API => '/wurk-api'` and `run Wurk::API` both work.
      #
      # App and its dependencies (Rack::Request among them) load on the first
      # request rather than at `require "wurk"`. The HTTP API is off unless a
      # host mounts it, and eager-loading it cost every swarm child ~1.2 MB of
      # pre-fork heap and measurably slower boot for a surface it never serves.
      def call(env)
        app.call(env)
      end

      # Whether the API should answer for `path` — the request path relative to
      # wherever it was mounted. The engine's conditional mount (config/
      # routes.rb) is a constraint over this, which settles two things a bare
      # `mount` could not:
      #
      #   * Off means absent. With no token registered the constraint fails,
      #     Rails falls through to the next route, and the surface does not
      #     exist — not a 401 advertising one that does (07 plan, step 1).
      #     Asked per request, not at draw time: routes load once at boot, and
      #     a host is free to register its token after that (a Puma-cluster web
      #     process never enters server mode, so its `configure_server` block
      #     has not run by then).
      #   * Nested in the engine, this plane shares the /api prefix with the
      #     dashboard's own JSON API. Without the version check a mistyped
      #     dashboard path would fall through to the machine plane and draw a
      #     bearer challenge for a route that was never part of this contract.
      def serves?(path, config = ::Wurk.configuration)
        return false unless config.api_enabled?

        path == VERSION_PREFIX || path.start_with?(NESTED_PREFIX)
      end

      private

      # App is stateless, so every mount — engine-nested, separately mounted,
      # standalone — can share one instance.
      def app
        @app ||= begin
          require_relative 'api/app'
          App.new
        end
      end
    end
  end
end
