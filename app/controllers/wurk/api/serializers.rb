# frozen_string_literal: true

module Wurk
  module Api
    # Pure mapping from inspector objects → JSON-shaped Hashes for the
    # dashboard SPA. Keeping the serializers out of the controller lets the
    # action methods stay tiny and lets future endpoints share the same
    # field shapes without re-implementing them.
    module Serializers
      module_function

      def stats_payload(stats)
        {
          processed: stats.processed,
          failed: stats.failed,
          expired: stats.expired,
          scheduled_size: stats.scheduled_size,
          retry_size: stats.retry_size,
          dead_size: stats.dead_size,
          processes_size: stats.processes_size,
          enqueued: stats.enqueued,
          default_queue_latency: stats.default_queue_latency
        }
      end

      def queue_summary(summary)
        { name: summary.name, size: summary.size, latency: summary.latency, paused: summary.paused? }
      end

      def job_record(record)
        {
          jid: record.jid,
          klass: record.display_class,
          args: record.display_args,
          queue: record.queue,
          enqueued_at: record.enqueued_at&.to_f,
          created_at: record.created_at&.to_f
        }
      end

      def sorted_entry(entry)
        job_record(entry).merge(
          score: entry.score,
          at: entry.at.to_f,
          error_class: entry['error_class'],
          error_message: entry['error_message'],
          retry_count: entry['retry_count']
        )
      end

      def process_row(process)
        {
          identity: process.identity,
          hostname: process['hostname'],
          pid: process['pid'],
          tag: process.tag,
          concurrency: process['concurrency'],
          busy: process['busy'],
          beat: process['beat'],
          quiet: process.stopping?,
          rss: process['rss'],
          rtt_us: process['rtt_us'],
          labels: process.labels,
          queues: process.queues,
          version: process.version,
          embedded: process.embedded?
        }
      end

      def limiter_row(name, meta)
        {
          name: name,
          type: meta['type'].to_s,
          fingerprint: meta['fingerprint'].to_s,
          options: parse_options(meta['options'])
        }
      end

      def cron_row(loop_obj, now_epoch)
        {
          lid: loop_obj.lid,
          schedule: loop_obj.schedule,
          klass: loop_obj.klass,
          queue: loop_obj.queue,
          tz: loop_obj.tz_name,
          paused: loop_obj.paused?,
          args: loop_obj.args,
          next_fire_at: loop_obj.next_fire_at(now_epoch)
        }
      end

      def metric_row(klass, totals)
        { klass: klass, processed: totals[:p], failed: totals[:f], runtime_ms: totals[:ms] }
      end

      def parse_options(raw)
        return {} if raw.nil? || raw.to_s.empty?

        ::JSON.parse(raw)
      rescue ::JSON::ParserError
        {}
      end
    end
  end
end
