# frozen_string_literal: true

module Wurk
  module UniqueJobs
    # `SidekiqUniqueJobs.reflect { |on| on.lock_failed { |item| ... } }`: one
    # callback per event, the gem's event names.
    class Reflections
      REFLECTIONS = %i[
        after_unlock_callback_failed debug duplicate error execution_failed lock_failed locked
        reschedule_failed rescheduled timeout unknown_sidekiq_worker unlock_failed unlocked
      ].freeze

      REFLECTIONS.each do |name|
        define_method(name) do |&block|
          raise NoBlockGiven, 'block required' unless block

          @reflections[name] = block
        end
      end

      def initialize
        @reflections = {}
      end

      def dispatch(reflection, *)
        if (block = @reflections[reflection])
          block.call(*)
        elsif misconfigured?(reflection)
          raise NoSuchNotificationError, reflection
        end
        nil
      end

      def configured?(reflection) = REFLECTIONS.include?(reflection)
      def misconfigured?(reflection) = !configured?(reflection)
    end

    module Reflectable
      def reflect(reflection, *)
        UniqueJobs.reflections.dispatch(reflection, *)
        nil
      rescue UniqueJobsError => e
        UniqueJobs.logger.error(e)
        nil
      end
    end

    # The gem's log helpers: off with `config.logger_enabled = false`, and a
    # message about a job names its lock, queue, class, jid and digest.
    module Logging
      LEVELS = %i[debug info warn error fatal].freeze

      LEVELS.each do |level|
        define_method(:"log_#{level}") do |message = nil, item = nil, &block|
          return unless UniqueJobs.logging?

          UniqueJobs.logger.public_send(level, build_message(message, item), &block)
          nil
        end
      end

      def logger = UniqueJobs.logger

      def build_message(message, item = nil)
        return message if message.nil? || item.nil?

        details = item.slice(LOCK, QUEUE, CLASS, JID, LOCK_DIGEST).map { |key, value| "#{key}=#{value}" }
        "#{message} (#{details.join(' ')})"
      end
    end
  end
end
