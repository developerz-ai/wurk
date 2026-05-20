# frozen_string_literal: true

module Wurk
  # Sidekiq 7+ alias for Wurk::Worker. `include Wurk::Job` and
  # `include Sidekiq::Job` are the same surface.
  module Job
    def self.included(base)
      base.include(Wurk::Worker)
    end
  end
end
