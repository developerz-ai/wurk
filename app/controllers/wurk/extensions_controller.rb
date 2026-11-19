# frozen_string_literal: true

require 'wurk/web/dashboard/extension_actions'

module Wurk
  # The engine's transport for third-party Web extensions
  # (Wurk::Web::Dashboard::ExtensionActions). Inherits DashboardController for
  # the shell an /ext URL that is the SPA's own client route falls back to.
  class ExtensionsController < DashboardController
    # Extension forms carry no Rails CSRF token — SameOriginGuard supplies
    # Sidekiq's same-origin CSRF defense (spec §25.1) in its place.
    include SameOriginGuard
    include ::Wurk::Web::Dashboard::ExtensionActions
  end
end
