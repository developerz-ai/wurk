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

      Wurk::Swarm.new(topology: Wurk.configuration.topology).boot
    end
  end
end
