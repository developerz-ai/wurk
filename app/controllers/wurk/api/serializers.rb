# frozen_string_literal: true

module Wurk
  module Api
    # Pure mapping from inspector objects → JSON-shaped Hashes for the
    # dashboard SPA. Keeping the serializers out of the controller lets the
    # action methods stay tiny and lets future endpoints share the same
    # field shapes without re-implementing them.
    module Serializers
      module_function

      # Wire-shape consumed by the React dashboard's landing page + SSE feed.
      # Field names match the SPA's `StatsSnapshot` interface in
      # frontend/src/hooks/useSSE.ts — keep them in sync. The canonical
      # Sidekiq-compatible accessors on Wurk::Stats use `_size` suffixes;
      # this serializer renames them for the dashboard's wire shape only.
      def stats_payload(stats)
        {
          processed: stats.processed,
          failed: stats.failed,
          expired: stats.expired,
          enqueued: stats.enqueued,
          busy: stats.workers_size,
          scheduled: stats.scheduled_size,
          retries: stats.retry_size,
          dead: stats.dead_size,
          processes: stats.processes_size,
          latency: stats.default_queue_latency,
          queues: stats.queue_summaries.map { |q| queue_summary(q) }
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
          options: parse_options(meta['options']),
          status: limiter_status(name, meta)
        }
      end

      # Reconstruct the limiter (read-only, `register: false`) just to read
      # its uniform `{ used, limit, reset_at, available? }` status for the
      # Limits tab. Best-effort: a malformed meta hash yields nil rather than
      # 500-ing the whole list.
      def limiter_status(name, meta)
        limiter = ::Wurk::Limiter.build(name, meta['type'], parse_options(meta['options']))
        limiter&.status
      rescue StandardError
        nil
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
          last_fire_at: loop_obj.last_fired_at,
          next_fire_at: loop_obj.next_fire_at(now_epoch)
        }
      end

      def metric_row(klass, totals)
        { klass: klass, processed: totals[:p], failed: totals[:f], runtime_ms: totals[:ms] }
      end

      # One point in a cluster-total time-series (Wurk::Metrics::Query.history).
      # `at` is epoch seconds at the bucket start.
      def history_point(row)
        { at: row[:at], processed: row[:p], failed: row[:f], runtime_ms: row[:ms] }
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
