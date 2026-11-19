# frozen_string_literal: true

require 'rack'
require 'uri'

module Wurk
  class Web
    # Sidekiq's CSRF model (spec §25.1) for the dashboard's token-less,
    # cookie-authenticated surfaces, on every mount (the engine's
    # SameOriginGuard and the standalone Rack app both ask here). A cross-site
    # page can drive a victim's browser but cannot forge
    # `Sec-Fetch-Site: same-origin` (the browser sets it).
    #
    # Browsers send Fetch Metadata only to potentially-trustworthy origins
    # (HTTPS, localhost), so a dashboard over plain HTTP on a LAN host never
    # sees it. Then the request's `Origin` — or, when absent, its `Referer` —
    # must be exactly this request's scheme, host and port (owner decision U9,
    # #101 W3). Neither header present is denied: only a non-browser client
    # omits both, and it carries no ambient session cookie to abuse.
    module SameOrigin
      SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

      module_function

      def allowed?(env)
        return true if SAFE_METHODS.include?(env['REQUEST_METHOD'])

        site = env['HTTP_SEC_FETCH_SITE']
        site ? site == 'same-origin' : same_origin_source?(::Rack::Request.new(env))
      end

      def same_origin_source?(request)
        source = [request.get_header('HTTP_ORIGIN'), request.referer].find { |value| !value.to_s.empty? }
        return false unless source

        uri = ::URI.parse(source)
        [uri.scheme, uri.host, uri.port] == [request.scheme, request.host, request.port]
      rescue ::URI::InvalidURIError
        false
      end
    end
  end
end
