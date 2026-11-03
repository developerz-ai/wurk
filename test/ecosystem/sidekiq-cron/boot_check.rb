# frozen_string_literal: true

# sidekiq-cron's own suite never boots a Launcher, so it stayed green while Wurk
# discarded the gem's poller and no cron job ever fired. Asserts jobs are enqueued
# and run from a schedule.
#
# Run under the harness bundle: BUNDLE_GEMFILE=test/ecosystem/sidekiq-cron/Gemfile
#   ECOSYSTEM_CHECKOUT=<checkout> REDIS_URL=<private server>/15 bundle exec ruby boot_check.rb

require 'sidekiq'
require 'sidekiq-cron'
require_relative '../boot_check_support'

BootCheck.load_into_worker

class BootCheckTick
  include Sidekiq::Job

  def perform = BootCheck.record(at: Time.now.to_f)
end

Sidekiq::Cron.configure { |c| c.cron_poll_interval = 1 }

Sidekiq.configure_server do |config|
  config.on(:startup) do
    Sidekiq::Cron::Job.load_from_hash!(
      { 'boot_check' => { 'cron' => '* * * * * *', 'class' => 'BootCheckTick', 'active_job' => false } },
      source: 'schedule'
    )
  end
end

BootCheck.drive(__FILE__, 'sidekiq-cron') { BootCheck.rows.size >= 2 }
