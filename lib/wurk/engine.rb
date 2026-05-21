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

    # Precompiled SPA lives in vendor/assets/dashboard; the engine serves
    # those files as static assets under the mount point.
    initializer 'wurk.assets' do |app|
      assets_path = Wurk::Engine.root.join('vendor', 'assets', 'dashboard')
      if assets_path.exist?
        app.middleware.insert_before(
          ::ActionDispatch::Static,
          ::Rack::Static,
          urls: ['/wurk-assets'],
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

    # Engine-scoped Rack middleware for the `Wurk::Web.configure` authorization
    # hook (sidekiq-ent §9.2). Inserted into the engine — not the host — so
    # the host's own controllers stay unaffected; only requests routed under
    # the mount point pass through.
    middleware.use ::Wurk::Web::Authorization
  end
end
