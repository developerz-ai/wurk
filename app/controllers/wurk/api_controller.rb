# frozen_string_literal: true

require_relative 'api/serializers'
require_relative 'api/pagination'

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

    skip_forgery_protection only: %i[stream]

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
      names = ::Wurk.redis { |c| c.call('SMEMBERS', ::Wurk::Limiter::LIST_KEY) }.sort
      render json: names.map { |name| ::Wurk::Api::Serializers.limiter_row(name, limiter_meta(name)) }
    end

    def cron
      now = ::Time.now.to_i
      render json: ::Wurk::Cron::LoopSet.new.map { |lp| ::Wurk::Api::Serializers.cron_row(lp, now) }
    end

    def metrics
      minutes = ::Wurk::Api::Pagination.clamp_int(params[:minutes], 1, ::Wurk::Metrics::Query::MAX_MINUTES, 60)
      rows = ::Wurk::Metrics::Query.top_jobs(minutes: minutes, class_filter: params[:substr])
      render json: { minutes: minutes, top_jobs: rows.map { |(klass, totals)| ::Wurk::Api::Serializers.metric_row(klass, totals) } }
    rescue ::Wurk::Metrics::Query::WindowTooWide => e
      render json: { error: e.message }, status: :bad_request
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
  end
end
