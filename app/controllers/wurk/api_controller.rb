# frozen_string_literal: true

require_relative 'api/serializers'
require_relative 'api/pagination'
require 'wurk/web'

module Wurk
  # JSON APIs consumed by the React SPA. Action methods stay thin; mapping to
  # the wire shape lives in `Wurk::Api::Serializers`, and pagination lives in
  # `Wurk::Api::Pagination`. SSE lives in #stream.
  #
  # Wire-compat: every payload field reads from the canonical Wurk inspector
  # objects (Stats, Queue, RetrySet, ScheduledSet, DeadSet, ProcessSet,
  # BatchSet, Cron::LoopSet) so dashboards stay aligned with the Redis schema
  # in `docs/target/sidekiq-{free,pro,ent}.md`.
  class ApiController < ApplicationController
    include ActionController::Live

    STREAM_TICK_SECONDS = 2.0
    STREAM_MAX_DURATION = 600.0

    skip_forgery_protection only: %i[
      stream reset_limiter pause_cron unpause_cron enqueue_cron
    ]

    def stats
      render json: ::Wurk::Api::Serializers.stats_payload(::Wurk::Stats.new)
    end

    def queues
      render json: ::Wurk::Stats.new.queue_summaries.map { |q| ::Wurk::Api::Serializers.queue_summary(q) }
    end

    def queue
      q = ::Wurk::Queue.new(params[:name].to_s)
      page = ::Wurk::Api::Pagination.window(params)
      jobs = ::Wurk::Api::Pagination.slice(q, page) { |rec| ::Wurk::Api::Serializers.job_record(rec) }
      render json: {
        name: q.name, size: q.size, latency: q.latency, paused: q.paused?,
        page: page[:page], count: page[:count], jobs: jobs
      }
    end

    def retries   = render_sorted_set(::Wurk::RetrySet.new)
    def scheduled = render_sorted_set(::Wurk::ScheduledSet.new)
    def dead      = render_sorted_set(::Wurk::DeadSet.new)

    def processes
      render json: ::Wurk::ProcessSet.new.map { |p| ::Wurk::Api::Serializers.process_row(p) }
    end

    def batches
      set = ::Wurk::BatchSet.new
      page = ::Wurk::Api::Pagination.window(params)
      rows = ::Wurk::Api::Pagination.slice(set, page) { |status| status.data.transform_keys(&:to_sym) }
      render json: { total: set.size, page: page[:page], count: page[:count], batches: rows }
    end

    def limiters
      names = ::Wurk::Web::Enterprise::Limits.list(filter: params[:substr])
      render json: names.map { |name| ::Wurk::Api::Serializers.limiter_row(name, limiter_meta(name)) }
    end

    def reset_limiter
      ::Wurk::Web::Enterprise::Limits.reset(params[:name].to_s)
      render json: { ok: true }
    end

    def cron
      now = ::Time.now.to_i
      render json: ::Wurk::Cron::LoopSet.new.map { |lp| ::Wurk::Api::Serializers.cron_row(lp, now) }
    end

    def pause_cron   = render_cron_action(::Wurk::Web::Enterprise::Periodic.pause(params[:lid].to_s))
    def unpause_cron = render_cron_action(::Wurk::Web::Enterprise::Periodic.unpause(params[:lid].to_s))

    def enqueue_cron
      jid = ::Wurk::Web::Enterprise::Periodic.enqueue_now(params[:lid].to_s)
      return render(json: { error: 'unknown loop' }, status: :not_found) if jid.nil?

      render json: { ok: true, jid: jid }
    end

    def cron_history
      render json: { lid: params[:lid].to_s, history: ::Wurk::Web::Enterprise::Periodic.history(params[:lid].to_s) }
    end

    def metrics
      minutes = ::Wurk::Api::Pagination.clamp_int(params[:minutes], 1, ::Wurk::Metrics::Query::MAX_MINUTES, 60)
      rows = ::Wurk::Web::Enterprise::Historical.top(minutes: minutes, class_filter: params[:substr])
      render json: { minutes: minutes, top_jobs: rows.map { |(klass, totals)| ::Wurk::Api::Serializers.metric_row(klass, totals) } }
    rescue ::Wurk::Metrics::Query::WindowTooWide => e
      render json: { error: e.message }, status: :bad_request
    end

    def metrics_for_job
      klass = params[:klass].to_s
      minutes, hours = metrics_window(params)
      rows = ::Wurk::Web::Enterprise::Historical.for_job(klass, minutes: minutes, hours: hours)
      series = rows.map { |row| row.merge(at: row[:at].to_f) }
      render json: { klass: klass, minutes: minutes, hours: hours, series: series }
    rescue ::ArgumentError, ::Wurk::Metrics::Query::WindowTooWide => e
      render json: { error: e.message }, status: :bad_request
    end

    def search
      substr = params[:substr].to_s
      return render(json: { substr: substr, total: 0, hits: [] }) if substr.empty?

      hits = ::Wurk::Web::Search.new(substr, kinds: parse_search_kinds(params), limit: parse_search_limit(params)).to_a
      render json: { substr: substr, total: hits.size, hits: hits }
    end

    # SSE: one `event: stats` per tick with a fresh Stats snapshot. Caps at
    # `STREAM_MAX_DURATION` so a stale browser tab can't tie a Rails worker
    # forever — the client reconnects automatically when the stream closes.
    #
    # `?max_duration=` and `?tick=` are test/debug knobs; the SPA never sets
    # them. `?max_duration=0` emits one tick and closes.
    def stream
      stream_headers!
      clamp = ::Wurk::Api::Pagination.method(:clamp_float)
      tick = clamp.call(params[:tick], 0.0, STREAM_TICK_SECONDS, STREAM_TICK_SECONDS)
      max_dur = clamp.call(params[:max_duration], 0.0, STREAM_MAX_DURATION, STREAM_MAX_DURATION)
      sse = ::ActionController::Live::SSE.new(response.stream, retry: (STREAM_TICK_SECONDS * 1000).to_i)
      drive_stream(sse, tick, max_dur)
    end

    private

    def render_sorted_set(set)
      page = ::Wurk::Api::Pagination.window(params)
      total = set.size
      entries = ::Wurk::Api::Pagination.slice(set, page) { |entry| ::Wurk::Api::Serializers.sorted_entry(entry) }
      render json: { total: total, page: page[:page], count: page[:count], entries: entries }
    end

    def limiter_meta(name)
      raw = ::Wurk.redis { |c| c.call('HGETALL', "lmtr:#{name}") }
      raw.is_a?(Array) ? raw.each_slice(2).to_h : raw
    end

    def stream_headers!
      response.headers['Content-Type'] = 'text/event-stream'
      response.headers['Cache-Control'] = 'no-cache'
      response.headers['X-Accel-Buffering'] = 'no'
    end

    def drive_stream(sse, tick, max_dur)
      deadline = monotime + max_dur
      loop do
        sse.write(stream_tick_payload, event: 'stats')
        break if monotime >= deadline

        sleep tick
      end
    rescue ::IOError, ::ActionController::Live::ClientDisconnected
      # client closed; nothing to clean up.
    ensure
      sse.close
    end

    def monotime
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    def stream_tick_payload
      ::Wurk::Api::Serializers.stats_payload(::Wurk::Stats.new).merge(at: ::Time.now.to_f)
    end

    def render_cron_action(success)
      return render(json: { error: 'unknown loop' }, status: :not_found) unless success

      render json: { ok: true }
    end

    def parse_search_kinds(params)
      params[:kinds].is_a?(::Array) ? params[:kinds] : params[:kinds].to_s.split(',')
    end

    def parse_search_limit(params)
      ::Wurk::Api::Pagination.clamp_int(
        params[:limit], 1, ::Wurk::Web::Search::MAX_LIMIT, ::Wurk::Web::Search::DEFAULT_LIMIT
      )
    end

    # Resolves the per-class metrics window. `minutes:` wins when present;
    # `hours:` is used otherwise; default falls back to 60 minutes so callers
    # that pass neither still get a useful series.
    def metrics_window(params)
      pagination = ::Wurk::Api::Pagination
      minutes = pagination.clamp_int(params[:minutes], 1, ::Wurk::Metrics::Query::MAX_MINUTES, 60) if params[:minutes]
      hours   = pagination.clamp_int(params[:hours],   1, ::Wurk::Metrics::Query::MAX_HOURS,   24) if params[:hours]
      minutes ||= 60 if hours.nil?
      [minutes, hours]
    end
  end
end
