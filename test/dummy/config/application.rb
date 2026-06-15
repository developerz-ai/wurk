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

# Explicit require keeps the dummy order-independent under the shared test
# loader (a prior unit test may `require "wurk"` before Rails is loaded, which
# would make wurk.rb's auto-load guard a no-op). The plain-`require "wurk"`
# drop-in path from #246 is proven order-faithfully in
# test/unit/rails_autoload_test.rb (fresh subprocess, Rails present).
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
