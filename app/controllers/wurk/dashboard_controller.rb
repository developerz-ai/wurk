# frozen_string_literal: true

require 'wurk/web/dashboard/shell'

module Wurk
  # Serves the SPA shell (Wurk::Web::Dashboard::Shell). Everything else is JSON
  # from ApiController.
  class DashboardController < ApplicationController
    def index
      render layout: false, html: ::Wurk::Web::Dashboard::Shell.new(request, asset_base: asset_base).html.html_safe
    end

    private

    # AssetMount sits in the host's stack, so its URL carries the host's own
    # prefix (RAILS_RELATIVE_URL_ROOT, or a proxy's SCRIPT_NAME), not the
    # engine mount: `/app/wurk` serves its assets from `/app/wurk-assets`.
    def asset_base
      "#{request.get_header('ORIGINAL_SCRIPT_NAME').to_s.chomp('/')}#{::Wurk::Web::AssetMount::PREFIX}"
    end
  end
end
