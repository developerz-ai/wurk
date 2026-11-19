# frozen_string_literal: true

require_relative 'extension'
require_relative 'pool_scope'
require_relative 'same_origin'
require_relative 'stats_routes'

module Wurk
  class Web
    # Upstream-compatible class-level Rack surface (#204): Sidekiq apps do
    # `run Sidekiq::Web`, `mount Sidekiq::Web => "/sidekiq"`, and rack-test
    # ecosystem suites call `Sidekiq::Web.call(env)` directly. In a booted Rails
    # app the dashboard is the engine's, so those paths go there, through the
    # engine's own copy of the gates below. Without Rails this entry serves it
    # all itself: the machine-readable routes (StatsRoutes), the registered
    # third-party Web extensions (#187's renderer) under their own route paths,
    # and the dashboard — shell, bundle, JSON API, SSE and profiles — through
    # Dashboard::Routes, the engine's actions over plain Rack.
    #
    # The engine's CSRF model (spec §25.1, Web::SameOrigin): unsafe methods
    # must come from this origin.
    NOT_FOUND_HEADERS = { 'Content-Type' => 'text/plain' }.freeze
    CROSS_ORIGIN = [403, { 'content-type' => 'application/json; charset=utf-8' }.freeze,
                    ['{"error":"cross_origin"}'].freeze].freeze

    class << self
      # Class-level Rack entry: host middleware (`Wurk::Web.use`), then the
      # same `authorization` + read-only gate the engine mount runs, then the
      # extensions dispatcher. Sidekiq Enterprise gates `mount Sidekiq::Web`
      # with exactly these, and Wurk ships Ent, so an app that swapped the gem
      # keeps its authorization on this mount too.
      def call(env)
        return ::Wurk::Engine.call(env) if engine_page?(env)

        PoolScope.scope { config.rack_app(standalone_app).call(env) }
      end

      private

      # `defined?` so this never loads the engine: one loaded this late would have
      # no routes, and a plain Rack process has no Rails to load it into.
      def engine_page?(env)
        return false unless defined?(::Wurk::Engine) && ::Rails.application&.initialized?

        path = env['PATH_INFO'].to_s
        !::Wurk::API.engine_serves?(path) && !Extension::Renderer.route?(env['REQUEST_METHOD'], path)
      end

      # Memoized so `Config#rack_app`'s per-inner cache keeps hitting. No
      # machine-API hand-off: Wurk::API is never served under this mount.
      def standalone_app
        @standalone_app ||= Authorization.new(method(:dispatch), api_handoff: false)
      end

      def dispatch(env)
        return CROSS_ORIGIN.dup unless SameOrigin.allowed?(env)

        StatsRoutes.serve(env) || dispatch_to_extensions(env) || dashboard_routes.call(env) ||
          [404, NOT_FOUND_HEADERS.dup, ['Not Found']]
      end

      # Loaded on the first standalone request: a Rails app never needs it, and
      # loading it with Wurk::Web would close a require cycle through Web::Search.
      def dashboard_routes
        @dashboard_routes ||= begin
          require_relative 'dashboard/routes'
          Dashboard::Routes
        end
      end

      # First extension whose routes answer the path wins; a per-extension
      # "no such route" 404 keeps scanning so extensions can't shadow each
      # other, and is returned only when nothing else matched and the path is
      # one an extension declares. nil hands the path to the dashboard.
      def dispatch_to_extensions(env)
        not_found = nil
        config.extensions.each do |ext|
          result = extension_result(ext, env)
          next unless result
          return rackify(result) unless result[0] == 404

          not_found ||= result
        end
        rackify(not_found) if not_found && Extension::Renderer.route?(env['REQUEST_METHOD'], env['PATH_INFO'].to_s)
      end

      def extension_result(ext, env)
        Extension::Renderer.call(
          name: ext[:name], method: env['REQUEST_METHOD'],
          subpath: env['PATH_INFO'].to_s, env: env, mount: env['SCRIPT_NAME'].to_s,
          embed: false
        )
      end

      # Renderer returns [status, headers, String]; Rack wants an each-able body.
      def rackify((status, headers, body))
        [status, headers, body.is_a?(::Array) ? body : [body.to_s]]
      end
    end
  end
end
