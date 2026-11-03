# frozen_string_literal: true

# A lock taken at enqueue has to be released by a real worker's server middleware,
# and hold against a duplicate until then.

require 'sidekiq'
require 'sidekiq-unique-jobs'
require_relative '../boot_check_support'

BootCheck.load_into_worker

class BootCheckUniqueJob
  include Sidekiq::Job

  sidekiq_options lock: :until_executed, queue: 'default'

  def perform(run) = BootCheck.record(run: run)
end

Sidekiq.configure_client do |config|
  config.client_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Client }
end

Sidekiq.configure_server do |config|
  config.client_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Client }
  config.server_middleware { |chain| chain.add SidekiqUniqueJobs::Middleware::Server }
  SidekiqUniqueJobs::Server.configure(config)
end

BootCheck.drive(__FILE__, 'sidekiq-unique-jobs') do
  # Enqueued from the driver while the worker comes up. Whichever attempts land while
  # the lock is held return nil; once a run is recorded the lock has to be gone.
  next false unless Sidekiq::ProcessSet.new.size.positive?

  run = @run_args ||= rand(1 << 30)
  first = BootCheckUniqueJob.perform_async(run) unless BootCheck.rows.any?
  next false unless first.nil? && BootCheck.rows.any? { |row| row['run'] == run }

  @run_args = nil
  SidekiqUniqueJobs::Digests.new.entries(pattern: '*').empty?
end
