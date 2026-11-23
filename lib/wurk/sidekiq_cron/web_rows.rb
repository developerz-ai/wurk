# frozen_string_literal: true

module Wurk
  module SidekiqCron
    # sidekiq-cron entries on the dashboard's Cron page, beside the periodic
    # loops, with the same row shape and the same pause/unpause/enqueue/history
    # actions. A row's `lid` is `sc-` plus the hex of `namespace NUL name`, so
    # any name survives the URL path and cannot collide with a loop's lid.
    module WebRows
      PREFIX = 'sc-'

      module_function

      def id?(lid) = lid.to_s.start_with?(PREFIX)

      def lid_for(job) = "#{PREFIX}#{"#{job.namespace}\0#{job.name}".unpack1('H*')}"

      def rows(now = ::Time.now)
        Job.all('*').sort_by(&:sort_name).map { |job| row(job, now) }
      end

      def row(job, now) # rubocop:disable Metrics/AbcSize -- one flat row
        schedule = job.valid? ? job.schedule : nil
        {
          lid: lid_for(job), label: job.name, namespace: job.namespace, description: job.description,
          source: 'sidekiq-cron', schedule: job.cron, klass: job.klass.to_s, queue: job.queue_name_with_prefix,
          tz: schedule&.zone_name, paused: job.disabled?, args: job.args,
          last_fire_at: job.last_enqueue_time&.to_i, next_fire_at: schedule&.next_time(now)&.to_i
        }
      end

      def find(lid)
        namespace, name = [lid.to_s.delete_prefix(PREFIX)].pack('H*').force_encoding(::Encoding::UTF_8).split("\0", 2)
        name && Job.find(name, namespace)
      end

      def pause(lid) = (job = find(lid)) ? job.disable! : false

      def unpause(lid) = (job = find(lid)) ? job.enable! : false

      def enqueue_now(lid)
        job = find(lid)
        job&.enqueue!
      end

      # `[enqueued_at, jid]`, newest first, the periodic history's shape.
      def history(lid)
        job = find(lid)
        return [] unless job

        job.jid_history_from_redis.map { |entry| [::Time.parse(entry['enqueued'].to_s).to_i, entry['jid']] }
      end
    end
  end
end
