# frozen_string_literal: true

require 'rails/engine'
require_relative '../active_job/queue_adapters/wurk_adapter'
require_relative 'dashboard_manifest'
require_relative 'web'

module Wurk
  # Rails mountable engine. Owns the dashboard mount, the asset path for
  # the precompiled SPA, and (via the sibling railtie) the after_initialize
  # hook that boots the swarm.
  class Engine < ::Rails::Engine
    isolate_namespace Wurk

    config.generators do |g|
      g.test_framework :minitest, fixtures: false
    end

    # Rack::Files doesn't strip the URL prefix before file lookup, so
    # `/wurk-assets/assets/foo.js` would resolve under `vendor/assets/dashboard/
    # wurk-assets/assets/foo.js` — a path that doesn't exist. AssetMount
    # rewrites PATH_INFO to drop the `/wurk-assets` prefix before delegating
    # to Rack::Files, then falls through to the next middleware on 404 so
    # host-app routes outside the mount keep working.
    class AssetMount
      PREFIX = '/wurk-assets'

      def initialize(app, root:)
        @app   = app
        @files = ::Rack::Files.new(root)
      end

      def call(env)
        path = env[::Rack::PATH_INFO]
        return @app.call(env) unless path == PREFIX || path.start_with?("#{PREFIX}/")

        inner = env.dup
        stripped = path.delete_prefix(PREFIX)
        inner[::Rack::PATH_INFO] = stripped.empty? ? '/' : stripped
        response = @files.call(inner)
        response[0] == 404 ? @app.call(env) : response
      end
    end

    # Precompiled SPA lives in vendor/assets/dashboard; the engine serves
    # those files as static assets under the /wurk-assets mount point via
    # AssetMount (above).
    initializer 'wurk.assets' do |app|
      assets_path = Wurk::Engine.root.join('vendor', 'assets', 'dashboard')
      if assets_path.exist?
        app.middleware.insert_before(
          ::ActionDispatch::Static,
          ::Wurk::Engine::AssetMount,
          root: assets_path.to_s
        )
      end
    end

    # Fail boot in production if the precompiled bundle is missing or its
    # version doesn't match the gem. Dev and test skip — contributors don't
    # always have a fresh build, and Vite dev mode owns the shell directly.
    initializer 'wurk.dashboard_manifest_check' do
      next if ENV['WURK_VITE_DEV'] == '1'
      next unless ::Rails.env.production?

      ::Wurk::DashboardManifest.check!
    end

    # Engine-scoped Rack middleware. Inserted into the engine — not the host —
    # so the host's own controllers stay unaffected; only requests routed
    # under the mount point pass through.
    #
    #   * MiddlewareStack — host-app auth via `Wurk::Web.use` (#41). Outermost,
    #     so Devise/Warden/Sorcery run first and their `env` is visible to the
    #     authorization hook below.
    #   * Authorization — the `Wurk::Web.configure` authorization + read-only
    #     hook (sidekiq-ent §9.2), 403 on falsey.
    middleware.use ::Wurk::Web::MiddlewareStack
    middleware.use ::Wurk::Web::Authorization
  end
end
