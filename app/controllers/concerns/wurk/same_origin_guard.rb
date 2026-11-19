# frozen_string_literal: true

require 'wurk/web/same_origin'

module Wurk
  # Sidekiq's CSRF model (spec §25.1) for the engine's token-less, cookie-
  # authenticated controllers: the SolidJS SPA (JSON fetch) and host-registered
  # extension forms send no Rails authenticity token, so `protect_from_forgery`
  # can't apply. Unsafe methods must pass Wurk::Web::SameOrigin instead, the
  # same rule the standalone Rack mount applies.
  module SameOriginGuard
    extend ActiveSupport::Concern

    SAFE_METHODS = ::Wurk::Web::SameOrigin::SAFE_METHODS

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
      render json: { error: 'cross_origin' }, status: :forbidden unless ::Wurk::Web::SameOrigin.allowed?(request.env)
    end
  end
end
