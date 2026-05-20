# frozen_string_literal: true

require "rails/engine"
require_relative "../active_job/queue_adapters/wurk_adapter"

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
    initializer "wurk.assets" do |app|
      assets_path = Wurk::Engine.root.join("vendor", "assets", "dashboard")
      app.middleware.insert_before(
        ::ActionDispatch::Static,
        ::Rack::Static,
        urls: ["/wurk-assets"],
        root: assets_path.to_s
      ) if assets_path.exist?
    end
  end
end
