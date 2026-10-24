# frozen_string_literal: true

# Used by engine/* and request tests. Boots the dummy Rails app.

ENV['RAILS_ENV'] ||= 'test'
ENV['WURK_DISABLED'] = '1' # engine tests boot the host; integration tests
# opt back into forking explicitly.

require_relative 'dummy/config/environment'

require_relative 'test_helper'

require 'rails/test_help'
require 'rack/test'

module Wurk
  module Test
    class EngineCase < ::ActionDispatch::IntegrationTest
      include ::Rack::Test::Methods

      def app
        ::Rails.application
      end

      # Rails 7.1's ActiveJob::TestHelper force-enables a fresh TestAdapter on
      # ActiveJob::Base and on every job class that sets its own adapter, for
      # the duration of every test (`queue_adapter_for_test` defaults to
      # TestAdapter.new there). Rails 8.0+ defaults it to nil and leaves the
      # app's adapters alone, which is why these tests pass on 8.x. Engine
      # tests assert the real enqueue path through the dummy's :wurk adapter,
      # so return nil explicitly: a no-op on 8.x, and on 7.1 it un-masks the
      # adapter the app actually configured.
      def queue_adapter_for_test
        nil
      end
    end
  end
end
