# frozen_string_literal: true

require 'json'

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
      # Three missed beats at {Wurk::Heartbeat::BEAT_PAUSE} cadence, which is
      # also the window Wurk::Health calls a heartbeat stale, and half the
      # heartbeat key's TTL — so a process that stopped beating is reported
      # stale for ~30s before Redis reaps the row out from under this API.
      STALE_AFTER_SECONDS = ::Wurk::Heartbeat::BEAT_PAUSE * 3

      module_function

      # Seconds since this process last beat, measured against a `now` the
      # caller took once for the whole listing so rows never disagree by a
      # round trip. Floored at zero: `beat` is stamped by the beating process's
      # clock and this is read on another host's, so a skew of a few
      # milliseconds must not surface as a negative age.
      def beat_age_seconds(beat, now)
        [now - beat.to_f, 0.0].max.round(3)
      end

      def stale?(age) = age > STALE_AFTER_SECONDS

      # One live process. `beat_age_seconds` and `stale` are derived here
      # rather than left to the client: a client comparing `beat` against its
      # own clock is comparing two clocks, which is the one comparison this
      # roll-up exists to save it from.
      #
      # `leader` is passed in because the two callers learn it differently — a
      # listing compares against one memoized `dear-leader` read, a single
      # process asks itself — and neither should pay the other's round trips.
      def process_row(process, leader:, now:)
        declared(process, now).merge(measured(process, now)).merge(leader: leader)
      end

      # The half a process wrote about itself in the `info` JSON: who it is and
      # what it was configured to do. Split along the same seam the heartbeat
      # itself uses (Heartbeat#info_hash versus #beat_hash_args), so a field
      # that moves between the two halves upstream moves between these.
      def declared(process, now)
        {
          identity: process.identity, hostname: process['hostname'], pid: process['pid'],
          tag: process.tag, version: process.version, embedded: process.embedded?,
          concurrency: process['concurrency'], queues: process.queues,
          weights: process.weights, labels: process.labels,
          started_at: process['started_at'], uptime_seconds: uptime_seconds(process['started_at'], now)
        }
      end

      # The half its last beat measured, plus the two values derived from it.
      def measured(process, now)
        age = beat_age_seconds(process['beat'], now)
        {
          busy: process['busy'], rss_kb: process['rss'], rtt_us: process['rtt_us'],
          beat: process['beat'], beat_age_seconds: age, stale: stale?(age),
          quiet: process.stopping?
        }
      end

      # One in-flight job. `class`/`args` are the display view for the reason
      # {#job_record} gives, and `elapsed_seconds` is derived for the reason
      # `beat_age_seconds` is — the client's clock is not the swarm's.
      def work_row(process_id, thread_id, work, now:)
        record = work.job
        run_at = work.run_at.to_f
        {
          process_id: process_id, thread_id: thread_id, queue: work.queue,
          jid: record.jid, class: record.display_class, args: record.display_args,
          run_at: run_at, elapsed_seconds: [now - run_at, 0.0].max.round(3)
        }
      end

      # `available`, not the `available?` {Wurk::Limiter::Base#build_status}
      # keys it with: a trailing `?` is Ruby's convention for a predicate, not
      # JSON's for a Boolean field. `status` is null when the limiter's
      # metadata expired between the listing that named it and this read.
      def limiter_row(name, meta, status)
        {
          name: name,
          type: meta['type'].to_s,
          fingerprint: meta['fingerprint'].to_s,
          options: parse_options(meta['options']),
          status: status && {
            used: status[:used], limit: status[:limit],
            reset_at: status[:reset_at], available: status[:available?]
          }
        }
      end

      # One registered cron loop. `next_fire_at` is evaluated against a `now`
      # the caller took once, so every row in a listing answers "next after the
      # same instant" rather than drifting a row at a time.
      def cron_loop(loop_obj, now:)
        {
          lid: loop_obj.lid, schedule: loop_obj.schedule, class: loop_obj.klass,
          queue: loop_obj.queue, args: loop_obj.args, tz: loop_obj.tz_name,
          paused: loop_obj.paused?,
          last_fired_at: loop_obj.last_fired_at,
          next_fire_at: loop_obj.next_fire_at(now)
        }
      end

      def parse_options(raw)
        return {} if raw.nil? || raw.to_s.empty?

        ::JSON.parse(raw)
      rescue ::JSON::ParserError
        {}
      end

      # nil rather than 0 when the heartbeat carries no `started_at`: a process
      # of unknown age is not one that just booted.
      def uptime_seconds(started_at, now)
        return nil if started_at.nil?

        [now - started_at.to_f, 0.0].max.round(3)
      end

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
