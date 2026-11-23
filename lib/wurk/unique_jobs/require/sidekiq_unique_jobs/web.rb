# frozen_string_literal: true

# `require "sidekiq_unique_jobs/web"` without the gem: the Locks tabs on Wurk's dashboard.
require 'sidekiq_unique_jobs'
require 'sidekiq/web'
require 'wurk/unique_jobs/web'

Sidekiq::Web.configure { |config| Wurk::UniqueJobs::Web.register(config) }
