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
    # and are deferred, running only when server mode is entered — after the
    # rest of the app's initializers instead of in their place. RailsBoot
    # decides whether this process serves.
    initializer 'wurk.server_mode', before: :load_config_initializers do |app|
      Wurk::RailsBoot.boot_scheduled = true
      Wurk::RailsBoot.enter_server_mode_if_serving(app)
    end

    # Registered at gem load, so it runs ahead of the host's own hooks: one of
    # them can still replace or wrap the reloader.
    config.after_initialize do |app|
      Wurk::RailsBoot.install_reloader(app)
      Wurk::RailsBoot.boot(app) unless Wurk::RailsBoot.boot_scheduled?
    end

    # Appended to Rails' own Finisher so it runs dead last. A boot here sees what
    # a host's `after_initialize` configured (a Redis URL, say), and a forked
    # child has the routes and dev-reload hooks Rails installs after those hooks
    # fire, which it could never pick up later. `after:` can't express this: it
    # drags the whole Finisher chain ahead of initializers not yet run.
    #
    # Deferred to before_configuration because naming Rails::Application at load
    # would pull ActionDispatch into a host loading only rails/railtie.
    config.before_configuration do
      finisher = ::Rails::Application::Finisher
      unless finisher.initializers.any? { |i| i.name == Wurk::RailsBoot::BOOT_INITIALIZER }
        finisher.initializer(Wurk::RailsBoot::BOOT_INITIALIZER) { |app| Wurk::RailsBoot.boot(app) }
      end
    end
  end
end
