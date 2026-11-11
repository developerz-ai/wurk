# frozen_string_literal: true

require_relative 'extension'
require_relative 'pool_scope'
require_relative 'stats_routes'

module Wurk
  class Web
    # Upstream-compatible class-level Rack surface (#204): Sidekiq apps do
    # `run Sidekiq::Web`, `mount Sidekiq::Web => "/sidekiq"`, and rack-test
    # ecosystem suites call `Sidekiq::Web.call(env)` directly. This entry serves
    # the machine-readable routes (StatsRoutes) and the registered third-party
    # Web extensions (#187's renderer) under their own route paths. Everything
    # else is the dashboard, which is the engine's: in a booted Rails app the
    # request goes there, through the engine's own copy of the gates below, so
    # the stock install line shows the dashboard. Without an engine those paths
    # 404 rather than half-serve the SPA.
    #
    # Same CSRF model as upstream Sidekiq 8 and ExtensionsController (spec
    # §25.1): unsafe methods must carry `Sec-Fetch-Site: same-origin`.
    SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze
    NOT_FOUND_HEADERS = { 'Content-Type' => 'text/plain' }.freeze
    NO_ENGINE_FIX = 'Wurk serves its dashboard from its Rails engine, so this Rack app answers only ' \
                    'routes of registered Web extensions. Mount Sidekiq::Web or Wurk::Engine in a ' \
                    'Rails app to get the dashboard.'

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
        return [403, NOT_FOUND_HEADERS.dup, ['Forbidden']] unless safe_request?(env)

        StatsRoutes.serve(env) || dispatch_to_extensions(env)
      end

      def safe_request?(env)
        SAFE_METHODS.include?(env['REQUEST_METHOD']) ||
          env['HTTP_SEC_FETCH_SITE'] == 'same-origin'
      end

      # First extension whose routes answer the path wins; a per-extension
      # "no such route" 404 keeps scanning so extensions can't shadow each
      # other, and is returned only when nothing else matched.
      def dispatch_to_extensions(env)
        not_found = nil
        config.extensions.each do |ext|
          result = extension_result(ext, env)
          next unless result
          return rackify(result) unless result[0] == 404

          not_found ||= result
        end
        routed = not_found && Extension::Renderer.route?(env['REQUEST_METHOD'], env['PATH_INFO'].to_s)
        rackify(routed ? not_found : no_dashboard_here)
      end

      def no_dashboard_here
        unless @no_engine_warned
          @no_engine_warned = true
          ::Wurk.logger.warn { NO_ENGINE_FIX }
        end
        [404, NOT_FOUND_HEADERS.dup, NO_ENGINE_FIX]
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
