# frozen_string_literal: true

# Used by engine/* and request tests. Boots the dummy Rails app.

ENV["RAILS_ENV"] ||= "test"
ENV["WURK_DISABLED"] = "1" # engine tests boot the host; integration tests
                          # opt back into forking explicitly.

require_relative "dummy/config/environment"

require_relative "test_helper"

require "rails/test_help"
require "rack/test"

module Wurk
  module Test
    class EngineCase < ::ActionDispatch::IntegrationTest
      include ::Rack::Test::Methods

      def app
        ::Rails.application
      end
    end
  end
end
