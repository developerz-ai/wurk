# frozen_string_literal: true

# sentry-sidekiq reports through an error handler it adds at load time, so the
# report only happens if a real worker runs that handler. Nothing leaves the box:
# before_send records the event and drops it.

require 'sidekiq'
require 'sentry-sidekiq'
require_relative '../boot_check_support'

BootCheck.load_into_worker

class BootCheckFailingJob
  include Sidekiq::Job

  sidekiq_options retry: false

  def perform = raise('boot check failure')
end

Sentry.init do |config|
  config.dsn = 'http://key@127.0.0.1:1/1'
  config.background_worker_threads = 0
  config.before_send = lambda do |event, _hint|
    BootCheck.record(transaction: event.transaction)
    nil
  end
end

Sidekiq.configure_server do |config|
  config.on(:startup) { BootCheckFailingJob.perform_async }
end

BootCheck.drive(__FILE__, 'sentry-sidekiq') do
  BootCheck.rows.any? { |row| row['transaction'] == 'Sidekiq/BootCheckFailingJob' }
end
