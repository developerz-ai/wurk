# frozen_string_literal: true

require_relative 'extension'

module Wurk
  class Web
    # Upstream-compatible class-level Rack surface (#204): Sidekiq apps do
    # `run Sidekiq::Web`, `mount Sidekiq::Web => "/sidekiq"`, and rack-test
    # ecosystem suites call `Sidekiq::Web.call(env)` directly. Wurk's full
    # dashboard is the engine-mounted SPA; this standalone entry serves the
    # registered third-party Web extensions (#187's renderer) under their own
    # route paths — the surface ecosystem gems exercise. Non-extension paths
    # 404 rather than half-serving the SPA without its engine.
    #
    # Same CSRF model as upstream Sidekiq 8 and ExtensionsController (spec
    # §25.1): unsafe methods must carry `Sec-Fetch-Site: same-origin`.
    SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze
    NOT_FOUND_HEADERS = { 'Content-Type' => 'text/plain' }.freeze

    class << self
      def call(env)
        config.rack_app(method(:dispatch)).call(env)
      end

      private

      def dispatch(env)
        return [403, NOT_FOUND_HEADERS.dup, ['Forbidden']] unless safe_request?(env)

        dispatch_to_extensions(env)
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
        rackify(not_found || [404, NOT_FOUND_HEADERS.dup, 'Not Found'])
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
