# frozen_string_literal: true

require_relative '../wurk'
require_relative 'sidekiq_cron/configuration'
require_relative 'sidekiq_cron/namespace'
require_relative 'sidekiq_cron/job'
require_relative 'sidekiq_cron/poller'
require_relative 'sidekiq_cron/schedule_loader'
require_relative 'sidekiq_cron/web_rows'

module Wurk
  # sidekiq-cron, native: `Sidekiq::Cron` is this module whenever the
  # sidekiq-cron gem is not in the bundle. Same DSL (`Sidekiq::Cron::Job`,
  # `Sidekiq::Cron.configure`), same Redis keys and fields as the gem's 2.x,
  # so dropping the gem from a running fleet needs no data migration and a
  # disabled entry stays disabled across the swap.
  #
  # A store of its own, not the periodic loops (`Wurk::Cron`, `periodic` /
  # `loops:<lid>`): a loop is keyed by a hash of its schedule, a sidekiq-cron
  # entry by its name, and the gem's pods read only their own keys. The two
  # share the crontab parser and the cluster leader, nothing else.
  #
  # With the gem bundled this module never loads (lib/sidekiq/cron.rb hands
  # every require to the gem), so the gem's poller is the only one.
  # See docs/periodic-jobs.md.
  module SidekiqCron
    class << self
      attr_writer :configuration

      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration) if block_given?
        configuration
      end

      def reset!
        @configuration = Configuration.new
      end

      # True when `Sidekiq::Cron` is this module, so the Launcher starts its
      # poller and the dashboard lists its entries.
      def active?
        !defined?(::Sidekiq::Cron).nil? && ::Sidekiq::Cron.equal?(self)
      end
    end
  end
end

Sidekiq::Cron = Wurk::SidekiqCron unless Sidekiq.const_defined?(:Cron, false) && Sidekiq.autoload?(:Cron).nil?
