# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_dispatch/railtie"

Bundler.require(*Rails.groups)

require "wurk/rails"

module Dummy
  class Application < ::Rails::Application
    config.load_defaults 7.1
    config.eager_load = false

    # The host app picks the adapter. The dummy uses Wurk so engine tests
    # exercise the integration the way a real consumer would.
    config.active_job.queue_adapter = :wurk

    # Skip auto-fork in the dummy unless an integration test opts in.
    ENV["WURK_DISABLED"] ||= "1"
  end
end
