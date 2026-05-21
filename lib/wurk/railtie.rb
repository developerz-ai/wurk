# frozen_string_literal: true

require "rails/railtie"

module Wurk
  # Boot the swarm after the host app has fully initialized.
  # Skip when: WURK_DISABLED=1, Rails console mode, or Rails test env.
  # See docs/idea/03-process-model.md for the exact ordering.
  class Railtie < ::Rails::Railtie
    config.after_initialize do |app|
      next if ENV["WURK_DISABLED"] == "1"
      next if defined?(::Rails::Console)
      next if ::Rails.env.test?

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
  end
end
