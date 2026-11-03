# frozen_string_literal: true

# The gem's server middleware has to see a real worker's failures. Its own suite
# drives the middleware by hand.

require 'sidekiq'
require 'sidekiq-failures'
require_relative '../boot_check_support'

BootCheck.load_into_worker

class BootCheckFailingJob
  include Sidekiq::Job

  sidekiq_options retry: false

  def perform = raise('boot check failure')
end

Sidekiq.configure_server do |config|
  config.on(:startup) { BootCheckFailingJob.perform_async }
end

BootCheck.drive(__FILE__, 'sidekiq-failures') do
  Sidekiq::Failures::FailureSet.new.any? { |entry| entry['error_message'] == 'boot check failure' }
end
