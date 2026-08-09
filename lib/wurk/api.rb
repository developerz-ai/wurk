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

    # A path that names *some* version of this plane — `/v1`, `/v2/jobs`, not
    # `/v1x` and not the dashboard's own `/stats`. Version-shaped rather than
    # `v1`-only because the mount has to claim a version it does not serve in
    # order for App to answer it `unsupported_api_version`, which is what the
    # standalone and separately-mounted modes already do. Claiming only `/v1`
    # would leave mode 1 alone in falling through to the host's router, and a
    # client would learn "wrong version" from Rails' 404 in one deployment
    # shape and from a problem document naming the supported versions in the
    # other two.
    VERSION_PATH = %r{\A/v\d+(?:/|\z)}

    # Where mount mode 1 puts this plane inside the engine (config/routes.rb).
    # Named here because two callers have to agree on it: the mount itself, and
    # `Wurk::Web::Authorization`, which runs before routing and so sees the
    # engine-relative path with this prefix still on it.
    ENGINE_MOUNT = '/api'

    # Rack env key the engine's Authorization middleware stamps when the
    # dashboard is read-only. It is how mount mode 1 — and only mode 1 —
    # inherits `WURK_WEB_READ_ONLY`: a separately mounted or standalone API is
    # a different deployment and opts in on its own (`config.api_read_only`).
    READ_ONLY_ENV = 'wurk.web.read_only'

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
      #     A version-shaped path is never one of the dashboard's, so this
      #     claims every version and lets App refuse the ones it cannot serve.
      def serves?(path, config = ::Wurk.configuration)
        return false unless config.api_enabled?

        VERSION_PATH.match?(path)
      end

      # The same question asked one prefix out, for callers that run before the
      # engine's mount has stripped it — `Wurk::Web::Authorization` is the only
      # one. It has to tell a machine-plane path from a dashboard one (both live
      # under /api) without loading App, which is why this is here and not there.
      def engine_serves?(path, config = ::Wurk.configuration)
        path.start_with?(ENGINE_MOUNT) && serves?(path.delete_prefix(ENGINE_MOUNT), config)
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
