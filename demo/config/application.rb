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

# sentry-rails registers its middleware and Active Job hooks through Railtie
# initializers, so it must load at boot — not from config/initializers.
if ENV["WURK_DEMO_REPORT_ERRORS"] == "1"
  require "sentry-ruby"
  require "sentry-rails"
end

module WurkDemo
  # The public demo app: a tiny Rails 8 host that runs Wurk as its job backend
  # and mounts the dashboard read-only. All the interesting behavior lives in
  # app/jobs and the producer (app/workloads/demo_producer.rb).
  class Application < ::Rails::Application
    config.load_defaults 8.0
    config.eager_load = ENV.fetch("RAILS_ENV", "development") == "production"
    config.active_job.queue_adapter = :wurk
  end
end
