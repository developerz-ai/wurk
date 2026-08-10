# frozen_string_literal: true

require 'erb'
require 'json'
require 'net/http'
require 'uri'
require 'wurk/web'

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
    # The SPA mount point, matched without its closing `>` so the locale hint
    # appends to whatever attributes the shell already carries.
    ROOT_DIV = '<div id="wurk-root"'
    # The theme hint's anchor. It is the one payload that has to land at the
    # *top* of <head> rather than before </head> with the others: the shell's
    # pre-paint script reads it, and that script runs before the stylesheet so
    # a host default never flashes the other palette.
    HEAD_OPEN = '<head>'

    def index
      render layout: false, html: decorate_shell(spa_html).html_safe
    end

    private

    def decorate_shell(html)
      inject_theme_default(inject_locale_hint(inject_head(html)))
    end

    def spa_html
      ENV['WURK_VITE_DEV'] == '1' ? fetch_vite_dev_shell : read_built_index
    end

    # Block form deliberately: a string replacement would interpret `\0`/`\&`
    # backreferences inside the host-configured JSON these scripts carry.
    def inject_head(html)
      html.sub('</head>') { "#{mount_base_script}#{host_translations_script}</head>" }
    end

    # The SPA is mount-agnostic: it reads window.__WURK_BASE__ to build every API
    # URL and its client-router base, so the same precompiled bundle works whether
    # the host mounts the engine at /wurk, /sidekiq, or /admin/jobs. script_name
    # is the mount prefix ("/sidekiq"), or "" at the app root. Injected into every
    # served shell (built and Vite-dev) so a non-/wurk mount needs no rebuild.
    def mount_base_script
      base = request.script_name.to_s.chomp('/')
      %(<script>window.__WURK_BASE__ = #{json_literal(base)};</script>\n  )
    end

    # Host copy overrides (Wurk::Web.config.translations), read once at SPA boot
    # by loadHostOverrides() in frontend/src/i18n/index.ts and deep-merged over
    # the shipped bundle for the locale in use.
    def host_translations_script
      overrides = ::Wurk::Web.config.translations
      return '' unless overrides.is_a?(::Hash) && !overrides.empty?

      %(<script type="application/json" id="wurk-i18n">#{json_literal(overrides)}</script>\n  )
    end

    # First-paint language hint, third in the SPA's precedence chain (`?locale=`
    # and a stored pick both outrank it), so it only decides the render for a
    # visitor who has never chosen. The negotiator returns a tag from the host's
    # offered list or nothing — request text never reaches the attribute — and
    # no hint at all is the right answer for an unrecognized language: the SPA
    # then falls through to navigator.languages.
    def inject_locale_hint(html)
      locale = negotiated_locale
      return html unless locale

      html.sub(ROOT_DIV) { %(#{ROOT_DIV} data-locale="#{::ERB::Util.html_escape(locale)}") }
    end

    # First-paint theme default (Wurk::Web.config.default_theme), last in the
    # SPA's precedence chain behind a stored pick — so it only decides the
    # palette for a visitor who has never chosen one. No config emits nothing
    # and leaves the SPA on 'system', which follows the visitor's OS.
    def inject_theme_default(html)
      theme = ::Wurk::Web.config.default_theme
      return html unless theme

      script = %(<script>window.__WURK_THEME__ = #{json_literal(theme)};</script>)
      html.sub(HEAD_OPEN) { "#{HEAD_OPEN}\n    #{script}" }
    end

    def negotiated_locale
      config = ::Wurk::Web.config
      header = request.get_header('HTTP_ACCEPT_LANGUAGE')
      ::Wurk::Web::LocaleNegotiator.call(header, offered: config.offered_locales) || config.default_locale
    end

    # JSON-encode a value as a literal inside <script>, escaping the sequences
    # that could otherwise break out of the tag. Both payloads are
    # host-configured, not request input, but the injection stays safe regardless.
    def json_literal(value)
      value.to_json.gsub(/[<>&]/) { |c| format('\u%04x', c.ord) }
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
