# frozen_string_literal: true

require 'json'
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
    # Vite serves the dev shell under its `base` (vite.config.ts), which is the
    # same path the engine mounts assets at — so derive these from
    # AssetMount::PREFIX to keep the Ruby side in lockstep. Fetching the server
    # root instead returns Vite's "did you mean /wurk-assets/" hint page, not the
    # shell (issue #181).
    VITE_DEV_HOST = 'http://localhost:5173'
    VITE_ASSET_BASE = "#{::Wurk::Engine::AssetMount::PREFIX}/".freeze # "/wurk-assets/"
    VITE_DEV_URL = "#{VITE_DEV_HOST}#{VITE_ASSET_BASE}".freeze
    INDEX_REL_PATH = ['vendor', 'assets', 'dashboard', 'index.html'].freeze

    def index
      render layout: false, html: inject_mount_base(spa_html).html_safe
    end

    private

    def spa_html
      ENV['WURK_VITE_DEV'] == '1' ? fetch_vite_dev_shell : read_built_index
    end

    # The SPA is mount-agnostic: it reads window.__WURK_BASE__ to build every API
    # URL and its client-router base, so the same precompiled bundle works whether
    # the host mounts the engine at /wurk, /sidekiq, or /admin/jobs. script_name
    # is the mount prefix ("/sidekiq"), or "" at the app root. Injected into every
    # served shell (built and Vite-dev) so a non-/wurk mount needs no rebuild.
    def inject_mount_base(html)
      html.sub('</head>', "#{mount_base_script}</head>")
    end

    def mount_base_script
      base = request.script_name.to_s.chomp('/')
      %(<script>window.__WURK_BASE__ = #{js_string(base)};</script>\n  )
    end

    # JSON-quote the mount prefix as a literal inside <script>, escaping the
    # sequences that could otherwise break out of the tag. The mount is
    # host-configured, not request input, but the injection stays safe regardless.
    def js_string(str)
      str.to_json.gsub(/[<>&]/) { |c| format('\u%04x', c.ord) }
    end

    def fetch_vite_dev_shell
      uri = ::URI.parse(VITE_DEV_URL)
      rewrite_dev_asset_urls(::Net::HTTP.get(uri))
    rescue ::StandardError => e
      raise "Wurk dashboard: cannot reach Vite dev server at #{VITE_DEV_URL} " \
            "(#{e.class}: #{e.message}). Run `bin/rake frontend:dev` from the gem root."
    end

    # The shell's entry URLs (`src="/wurk-assets/@vite/client"`,
    # `src="/wurk-assets/src/main.tsx"`) are base-absolute, but the page is
    # served from the host origin (e.g. :3000), where that path only maps to the
    # built bundle. Point them back at the Vite dev server so the browser loads
    # the modules + HMR client straight from Vite (CORS-enabled in dev). Vite's
    # `server.origin` covers runtime-generated asset URLs but not these entry
    # tags, so rewrite them here.
    def rewrite_dev_asset_urls(html)
      html.gsub(/(["'])#{::Regexp.escape(VITE_ASSET_BASE)}/, "\\1#{VITE_DEV_URL}")
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
