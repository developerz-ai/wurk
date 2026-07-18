# frozen_string_literal: true

module Wurk
  # Sidekiq's CSRF model (spec §25.1) for the dashboard's token-less, cookie-
  # authenticated surfaces. The SolidJS SPA (JSON fetch) and host-registered
  # extension forms send no Rails authenticity token, so `protect_from_forgery`
  # can't apply — guard unsafe methods with a same-origin check instead. A
  # cross-site page can drive a victim's browser but cannot forge
  # `Sec-Fetch-Site: same-origin` (the browser sets it); a missing header is
  # denied too, since only a non-browser client omits it and it carries no
  # ambient session cookie to abuse.
  #
  # Mirrors the standalone Rack surface (Wurk::Web#safe_request?) so every
  # mutating dashboard entry point enforces one rule.
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

    def verify_same_origin!
      head :forbidden unless safe_request?
    end

    def safe_request?
      SAFE_METHODS.include?(request.request_method) ||
        request.headers['Sec-Fetch-Site'] == 'same-origin'
    end
  end
end
