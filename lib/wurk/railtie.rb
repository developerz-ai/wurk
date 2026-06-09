# frozen_string_literal: true

require 'rails/railtie'

module Wurk
  # Boot the swarm after the host app has fully initialized.
  # Skip when: WURK_DISABLED=1, Rails console mode, or Rails test env.
  # See docs/idea/03-process-model.md for the exact ordering.
  class Railtie < ::Rails::Railtie
    # This Rails process forks the workers, so it IS the server. Enter server
    # mode BEFORE config/initializers load — otherwise the app's
    # `Sidekiq.configure_server` blocks gate on `config.server?` (still false)
    # and are silently dropped. Gated identically to the swarm boot: a process
    # that won't run workers (disabled / console / test) is not a server.
    initializer 'wurk.server_mode', before: :load_config_initializers do
      Wurk.enter_server_mode unless Wurk::Railtie.skip_boot?
    end

    config.after_initialize do |_app|
      next if Wurk::Railtie.skip_boot?

      swarm = Wurk::Swarm.new(topology: Wurk.configuration.topology)
      swarm.boot
      # Embedded mode keeps the Rails process serving HTTP; supervise must
      # run somewhere or signal_queue never drains, crashed children never
      # respawn, and memory pressure checks never fire. Background thread
      # leaves the host's main thread free for Rails.
      Thread.new do
        swarm.supervise
      rescue StandardError => e
        Wurk.configuration.logger.error { "wurk supervisor thread died: #{e.class}: #{e.message}" }
      end
    end

    # A process that won't run workers isn't a server: skip both server mode
    # and the swarm boot. Console mode is detected reliably here — the console
    # command file defines ::Rails::Console before initializers run.
    def self.skip_boot?
      ENV['WURK_DISABLED'] == '1' || defined?(::Rails::Console) || ::Rails.env.test?
    end
  end
end
