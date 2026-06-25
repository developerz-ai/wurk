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

      # Host-registered custom job-info rows (spec §25.2) ride along as
      # `custom_rows` for the SPA's job-detail modal (see Config#job_info_pairs,
      # which gates on registration so the common no-extension case is free).
      # Divergence: wurk evaluates these during job-list serialization — the SPA
      # renders job detail client-side — not in a dedicated server detail view.
      def job_record(record)
        base = {
          jid: record.jid,
          klass: record.display_class,
          args: record.display_args,
          queue: record.queue,
          enqueued_at: record.enqueued_at&.to_f,
          created_at: record.created_at&.to_f
        }
        rows = ::Wurk::Web.config.job_info_pairs(record)
        rows.empty? ? base : base.merge(custom_rows: rows)
      end

      def sorted_entry(entry)
        job_record(entry).merge(
          score: entry.score,
          at: entry.at.to_f,
          error_class: entry['error_class'].to_s,
          error_message: entry['error_message'].to_s,
          retry_count: entry['retry_count'],
          error_backtrace: entry.error_backtrace
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
          started_at: process['started_at'],
          cpu_model: process['cpu_model'],
          cores: process['cores'],
          memory_total_kb: process['memory_total_kb'],
          labels: process.labels,
          queues: process.queues,
          version: process.version,
          embedded: process.embedded?
        }
      end

      # One in-flight job (WorkSet row) for the Busy page's process detail.
      def work_row(process_id, thread_id, work)
        record = work.job
        {
          process_id: process_id,
          thread_id: thread_id,
          queue: work.queue,
          klass: record.display_class,
          args: record.display_args,
          jid: record.jid,
          run_at: work.run_at.to_f
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

      # One queue's size/latency gauge series (Wurk::Metrics::Query.queue_history).
      # `points` are oldest→newest; `at` is epoch seconds at the bucket start,
      # `size` is queue depth, `latency` is head-of-line wait in seconds.
      def queue_history_series(row)
        { name: row[:name], points: row[:points].map { |p| { at: p[:at], size: p[:size], latency: p[:latency] } } }
      end

      def parse_options(raw)
        return {} if raw.nil? || raw.to_s.empty?

        ::JSON.parse(raw)
      rescue ::JSON::ParserError
        {}
      end

      # One profile row for the Profiles pane. `key` drives the view/data links.
      def profile_record(rec)
        {
          key: rec.key,
          jid: rec.jid,
          token: rec.token,
          type: rec.type,
          size: rec.size,
          elapsed: rec.elapsed,
          started_at: rec.started_at&.to_i
        }
      end
    end
  end
end
