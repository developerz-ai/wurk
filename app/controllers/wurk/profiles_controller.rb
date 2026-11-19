# frozen_string_literal: true

require 'wurk/web/dashboard/profile_actions'

module Wurk
  # The engine's transport for the profile routes
  # (Wurk::Web::Dashboard::ProfileActions).
  class ProfilesController < ApplicationController
    include SameOriginGuard
    include ::Wurk::Web::Dashboard::ProfileActions

    before_action :require_listed_profile
  end
end
