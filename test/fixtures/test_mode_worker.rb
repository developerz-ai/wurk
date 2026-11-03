# frozen_string_literal: true

# Loaded by a real `wurk` / `wurkswarm` with -r. Turns fake mode on as it loads,
# which is what rspec-sidekiq does outside a Gemfile's test group, then enqueues
# from a worker the way a cron tick or a job would.
require 'sidekiq'

Sidekiq.testing!(:fake)

class TestModeWorkerJob
  include Sidekiq::Job

  def perform(path) = File.write(path, 'ran')
end

Sidekiq.configure_server do |config|
  config.on(:startup) do
    TestModeWorkerJob.set(queue: ENV.fetch('WURK_TEST_QUEUE')).perform_async(ENV.fetch('WURK_TEST_OUT'))
  end
end
