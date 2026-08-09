# frozen_string_literal: true

module Wurk
  module API
    # Wire shapes for the observe plane.
    #
    # Every value below is read off a canonical inspector — Stats, Queue,
    # JobRecord, SortedEntry — so the API and the dashboard cannot report
    # different numbers for the same Redis. Only the shape differs, and it
    # differs on purpose: the dashboard's serializers
    # (app/controllers/wurk/api/serializers.rb) answer to the SPA and change
    # whenever it does, and they reach into Wurk::Web for host-registered
    # extension rows — an engine dependency the API cannot take, because it
    # also runs standalone. Under /v1 these field names are a contract.
    module Serializers
      module_function

      # `default_queue_latency`, not the dashboard's `latency`: sitting beside
      # a `queues` array, a bare `latency` reads as the whole fleet's rather
      # than the `default` queue's, which is what Stats measures.
      def stats(snapshot)
        {
          processed: snapshot.processed,
          failed: snapshot.failed,
          expired: snapshot.expired,
          enqueued: snapshot.enqueued,
          busy: snapshot.workers_size,
          scheduled: snapshot.scheduled_size,
          retries: snapshot.retry_size,
          dead: snapshot.dead_size,
          processes: snapshot.processes_size,
          default_queue_latency: snapshot.default_queue_latency,
          queues: snapshot.queue_summaries.map { |summary| queue_summary(summary) }
        }
      end

      def queue_summary(summary)
        { name: summary.name, size: summary.size, latency: summary.latency, paused: summary.paused? }
      end

      # The same four gauges read off a Wurk::Queue instead of a pipelined
      # Stats::QueueSummary — three round trips rather than a share of one,
      # which is what asking about a single queue costs. Same field names on
      # purpose: a client that read a queue out of the listing and then fetched
      # it should not have to reshape anything.
      def queue_gauges(queue)
        { name: queue.name, size: queue.size, latency: queue.latency, paused: queue.paused? }
      end

      # `class` and `args` are the *display* view, the same one the dashboard
      # renders: an ActiveJob wrapper is unwrapped to the job the host actually
      # wrote, and an `encrypt: true` job's ciphertext argument is masked.
      # Serving `record.args` here would publish the raw encrypted envelope of
      # every such job over HTTP.
      def job_record(record)
        {
          jid: record.jid,
          class: record.display_class,
          args: record.display_args,
          queue: record.queue,
          enqueued_at: record.enqueued_at&.to_f,
          created_at: record.created_at&.to_f
        }
      end

      # `at` is the member's ZSET score in epoch seconds — when it is due to
      # retry, due to run, or when it died, depending on which set it came out
      # of. Emitted once: the score and the timestamp are the same number, and
      # a contract that ships both invites clients to disagree about which is
      # authoritative.
      def sorted_entry(entry)
        job_record(entry).merge(
          at: entry.at.to_f,
          retry_count: entry['retry_count'],
          error_class: entry['error_class'],
          error_message: entry['error_message'],
          failed_at: entry.failed_at&.to_f,
          retried_at: entry.retried_at&.to_f,
          error_backtrace: entry.error_backtrace
        )
      end
    end
  end
end
