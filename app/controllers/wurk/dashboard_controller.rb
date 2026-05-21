# frozen_string_literal: true

require 'net/http'
require 'uri'

module Wurk
  # Serves the SPA shell. Everything else is JSON from ApiController.
  #
  # Production: returns the precompiled index.html shipped in
  # vendor/assets/dashboard. The release pipeline (`frontend:build` →
  # `gem build`) writes both that file and the wurk-manifest.json validated
  # at engine boot.
  #
  # Development: when WURK_VITE_DEV=1 is set, fetches the shell from the
  # Vite dev server (default :5173) so contributors get HMR without
  # rebuilding the bundle on every change.
  class DashboardController < ApplicationController
    VITE_DEV_URL = 'http://localhost:5173/'
    INDEX_REL_PATH = ['vendor', 'assets', 'dashboard', 'index.html'].freeze

    def index
      render layout: false, html: spa_html.html_safe
    end

    private

    def spa_html
      ENV['WURK_VITE_DEV'] == '1' ? fetch_vite_dev_shell : read_built_index
    end

    def fetch_vite_dev_shell
      uri = ::URI.parse(VITE_DEV_URL)
      ::Net::HTTP.get(uri)
    rescue ::StandardError => e
      raise "Wurk dashboard: cannot reach Vite dev server at #{VITE_DEV_URL} " \
            "(#{e.class}: #{e.message}). Run `bin/rake frontend:dev` from the gem root."
    end

    def read_built_index
      path = ::Wurk::Engine.root.join(*INDEX_REL_PATH)
      unless path.exist?
        raise "Wurk dashboard: precompiled SPA index.html missing at #{path}. " \
              'Run `bin/rake frontend:build`.'
      end
      path.read
    end
  end
end
