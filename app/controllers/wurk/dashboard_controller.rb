# frozen_string_literal: true

module Wurk
  # Serves the SPA shell. Everything else is JSON from ApiController.
  class DashboardController < ApplicationController
    def index
      render layout: false, html: spa_html.html_safe
    end

    private

    def spa_html
      # TODO: read vendor/assets/dashboard/index.html in production,
      # or proxy the Vite dev server when WURK_VITE_DEV=1.
      "<!doctype html><html><body><div id='wurk-root'></div></body></html>"
    end
  end
end
