# frozen_string_literal: true

require 'erb'
require 'yaml'

module Wurk
  module SidekiqCron
    # The gem's startup load of `cron_schedule_file` (default
    # `config/schedule.yml`, falling back to `.yaml`), a Hash or an Array of
    # entries, ERB allowed. Runs on `:startup` in server processes only, and
    # not at all with `enabled = false`.
    class ScheduleLoader
      # The `:startup` hook: nothing when the gem owns Sidekiq::Cron, when
      # `enabled` is false, or when there is no schedule file.
      def self.on_startup
        return unless SidekiqCron.active? && SidekiqCron.configuration.enabled

        loader = new
        loader.load_schedule if loader.has_schedule_file?
      end

      def load_schedule
        case schedule
        when ::Hash then Job.load_from_hash!(schedule, source: 'schedule')
        when ::Array then Job.load_from_array!(schedule, source: 'schedule')
        else raise "Not supported schedule format. Confirm your #{schedule_file_name}"
        end
      end

      # rubocop:disable-next Naming/PredicatePrefix -- the gem's name
      def has_schedule_file? = ::File.exist?(schedule_file_name)

      private

      def schedule
        @schedule ||= ::YAML.safe_load(::ERB.new(::File.read(schedule_file_name)).result,
                                       permitted_classes: [::Symbol], aliases: true)
      end

      def schedule_file_name
        @schedule_file_name ||= begin
          name = SidekiqCron.configuration.cron_schedule_file.to_s
          ::File.exist?(name) ? name : name.sub(/\.yml\z/, '.yaml')
        end
      end
    end
  end
end

Wurk.configure_server { |config| config.on(:startup) { Wurk::SidekiqCron::ScheduleLoader.on_startup } }
