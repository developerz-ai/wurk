# frozen_string_literal: true

module Wurk
  # Sidekiq's CSRF model (spec §25.1) for the dashboard's token-less, cookie-
  # authenticated surfaces. The SolidJS SPA (JSON fetch) and host-registered
  # extension forms send no Rails authenticity token, so `protect_from_forgery`
  # can't apply — guard unsafe methods with a same-origin check instead. A
  # cross-site page can drive a victim's browser but cannot forge
  # `Sec-Fetch-Site: same-origin` (the browser sets it).
  #
  # Browsers send Fetch Metadata only to potentially-trustworthy origins
  # (HTTPS, localhost), so a dashboard over plain HTTP on a LAN host never sees
  # it. Then the request's `Origin` — or, when absent, its `Referer` — must be
  # exactly this request's scheme, host and port (owner decision U9, #101 W3).
  # Neither header present is denied: only a non-browser client omits both,
  # and it carries no ambient session cookie to abuse.
  #
  # The standalone Rack surface (Wurk::Web#safe_request?) applies the same
  # Sec-Fetch-Site rule without this fallback: it stays strict, so a
  # plain-HTTP standalone mount refuses unsafe requests (parity-divergences).
  module SameOriginGuard
    extend ActiveSupport::Concern

    # Non-mutating methods need no origin check. Matches Wurk::Web::SAFE_METHODS;
    # kept local so this engine concern carries no lib load-order dependency.
    SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

    included do
      # SPA/extension requests never carry a Rails CSRF token; the same-origin
      # check below is the CSRF defense in its place.
      skip_forgery_protection
      before_action :verify_same_origin!
    end

    private

    # The SPA's toast branches on this body to name the cause instead of
    # reading the 403 as read-only mode.
    def verify_same_origin!
      render json: { error: 'cross_origin' }, status: :forbidden unless safe_request?
    end

    def safe_request?
      return true if SAFE_METHODS.include?(request.request_method)

      site = request.headers['Sec-Fetch-Site']
      site ? site == 'same-origin' : same_origin_source?
    end

    def same_origin_source?
      source = request.headers['Origin'].presence || request.referer.presence
      return false unless source

      uri = ::URI.parse(source)
      [uri.scheme, uri.host, uri.port] == own_origin
    rescue ::URI::InvalidURIError
      false
    end

    def own_origin = [request.scheme, request.host, request.port]
  end
end
