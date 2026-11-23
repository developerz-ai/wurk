# frozen_string_literal: true

require_relative '../component'
require_relative '../timer_loop'

module Wurk
  module SidekiqCron
    # Fires due sidekiq-cron entries every `cron_poll_interval` seconds. The
    # Launcher runs one in every process, and only the cluster leader's ticks
    # do anything (`dear-leader`, as the periodic loops).
    #
    # The leader is the cheap half of exactly-once, not the guarantee: a leader
    # handover, or a sidekiq-cron gem pod still polling during a rollout, can
    # reach the same occurrence, and each entry's `:enqueued` ZADD lets exactly
    # one of them push it (Job#should_enqueue?).
    class Poller
      include Component

      def initialize(config)
        @config = config
        @timer = TimerLoop.new(SidekiqCron.configuration.cron_poll_interval.to_i)
        @thread = nil
      end

      def start
        return @thread if @thread

        @timer.reset
        @thread = safe_thread('sidekiq-cron-poller') do
          migrate
          @timer.run { tick }
        end
      end

      # Cleared only on a confirmed join, as the other leader-gated loops: a
      # tick still in flight would push next to the next leader's first one.
      def terminate
        @timer.terminate
        @thread = nil if @thread&.join(TimerLoop::JOIN_TIMEOUT)
      end

      def tick(now = ::Time.now.utc)
        return unless leader?

        enqueue(now)
      rescue StandardError => e
        handle_exception(e, { context: 'sidekiq-cron-poller' })
      end

      # One pass over every entry, bypassing the leader gate. Rescued per
      # entry, so one that raises on every poll cannot starve the rest.
      def enqueue(now = ::Time.now.utc)
        Job.all('*').each do |job|
          job.test_and_enqueue_for_time!(now) if job.valid?
        rescue StandardError => e
          handle_exception(e, { context: 'sidekiq-cron-poller', name: job.name, namespace: job.namespace })
        end
      end

      private

      # The gem does this as its poller starts; off the boot path here, so a
      # Redis blip costs the migration one boot, not the process.
      def migrate
        Job.migrate_old_jobs_if_needed!
      rescue StandardError => e
        handle_exception(e, { context: 'sidekiq-cron-migrate' })
      end
    end
  end
end
