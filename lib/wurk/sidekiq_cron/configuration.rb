# frozen_string_literal: true

module Wurk
  module SidekiqCron
    # `Sidekiq::Cron.configure { |c| ... }`: sidekiq-cron 2.4's knobs, same
    # names and defaults. `cron_poll_process_count` and the parsing mode are
    # accepted and validated as the gem does; neither changes anything here,
    # because only the cluster leader polls and natural language is refused.
    class Configuration
      PARSING_MODES = %i[single strict].freeze

      attr_accessor :cron_poll_interval, :cron_schedule_file, :cron_history_size, :default_namespace,
                    :available_namespaces, :reschedule_grace_period, :enabled
      attr_reader :natural_cron_parsing_mode, :cron_poll_process_count

      def initialize
        @cron_poll_interval = 30
        @cron_schedule_file = 'config/schedule.yml'
        @cron_history_size = 10
        @default_namespace = 'default'
        @available_namespaces = [@default_namespace]
        @natural_cron_parsing_mode = :single
        @reschedule_grace_period = 60
        @enabled = true
        @cron_poll_process_count = nil
      end

      def natural_cron_parsing_mode=(mode)
        raise ArgumentError, "Unknown natural cron parsing mode: #{mode.inspect}" unless PARSING_MODES.include?(mode)

        @natural_cron_parsing_mode = mode
      end

      def cron_poll_process_count=(count)
        unless count.is_a?(Integer) && count.positive?
          raise ArgumentError, "invalid cron process count: #{count.inspect}"
        end

        @cron_poll_process_count = count
      end
    end
  end
end
