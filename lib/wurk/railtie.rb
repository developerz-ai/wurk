# frozen_string_literal: true

require 'rails/railtie'
require 'active_support/ordered_options'
require_relative 'rails_boot'

module Wurk
  # Rails integration surface only: register the host-facing `config.wurk`
  # namespace and wire the two boot hooks to Wurk::RailsBoot. All boot policy
  # (skip/fork/embed/refuse, prefork detection) and execution lives there — this
  # class exists solely to invoke the coordinator from the Rails lifecycle.
  # See docs/idea/03-process-model.md for the exact ordering.
  class Railtie < ::Rails::Railtie
    # Host-facing config namespace. Pre-created so a host can write
    # `config.wurk.embed_in_web = true` in config/application.rb without a
    # NoMethodError — the setter needs the OrderedOptions to already exist.
    # Shared with the application config via Rails' Railtie::Configuration
    # @@options, so `Rails.application.config.wurk` reads back the same object.
    config.wurk = ::ActiveSupport::OrderedOptions.new

    # The gemspec ships no .rake files, so the railtie loads Wurk's
    # host-facing rake tasks itself for `bin/rails wurk:import:cron` to exist.
    rake_tasks { load File.expand_path('rake_tasks.rb', __dir__) }

    # Enter server mode BEFORE config/initializers load — otherwise the app's
    # `Sidekiq.configure_server` blocks gate on `config.server?` (still false)
    # and are dropped, each skip logging one WARN naming the gate
    # (`configure_server` / `server? is false`). RailsBoot decides whether this
    # process serves.
    initializer 'wurk.server_mode', before: :load_config_initializers do |app|
      Wurk::RailsBoot.enter_server_mode_if_serving(app)
    end

    config.after_initialize do |app|
      Wurk::RailsBoot.boot(app)
    end
  end
end
