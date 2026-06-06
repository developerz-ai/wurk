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

    HISTORY_WINDOW_UNITS = { 's' => 1, 'm' => 60, 'h' => 3600, 'd' => 86_400 }.freeze
    DEFAULT_HISTORY_WINDOW = 24 * 3600

    skip_forgery_protection only: %i[
      stream reset_limiter pause_cron unpause_cron enqueue_cron
      clear_queue delete_queue_job
      retries_bulk retries_all retry_job
      scheduled_bulk scheduled_all scheduled_job
      dead_bulk dead_all dead_job
    ]

    # Per-set action whitelists. Maps the SPA's action name to the
    # SortedEntry/JobSet method. Anything not listed 400s — keeps the bulk/
    # single dispatchers from reaching arbitrary methods off a request param.
    RETRY_ACTIONS     = { 'retry' => :retry, 'delete' => :delete, 'kill' => :kill }.freeze
    SCHEDULED_ACTIONS = { 'delete' => :delete, 'add_to_queue' => :add_to_queue }.freeze
    DEAD_ACTIONS      = { 'retry' => :retry, 'delete' => :delete }.freeze

    # Boot-time flags the SPA reads once to shape the UI (e.g. hide destructive
    # actions and show the read-only banner). Always a GET, so it stays
    # reachable while read-only mode blocks mutations.
    def meta
      config = ::Wurk::Web.config
      render json: { read_only: config.read_only?, read_only_message: config.read_only_message }
    end

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

    # Empties one queue (UNLINK list + drop from the `queues` set).
    def clear_queue
      ::Wurk::Queue.new(params[:name].to_s).clear
      render json: { ok: true }
    end

    # Removes a single job from a queue by jid. LREM matches exact bytes, so we
    # locate the record (Queue#find_job) and let it delete its own value.
    def delete_queue_job
      record = ::Wurk::Queue.new(params[:name].to_s).find_job(params[:jid].to_s)
      return render(json: { error: 'unknown job' }, status: :not_found) unless record

      render json: { ok: true, deleted: record.delete }
    end

    def retries   = render_sorted_set(::Wurk::RetrySet.new)
    def scheduled = render_sorted_set(::Wurk::ScheduledSet.new)
    def dead      = render_sorted_set(::Wurk::DeadSet.new)

    # --- Retry set mutations -------------------------------------------------
    def retry_job    = single_entry_action(::Wurk::RetrySet.new, RETRY_ACTIONS, params[:cmd])
    def retries_bulk = bulk_entry_action(::Wurk::RetrySet.new, RETRY_ACTIONS)

    def retries_all
      set = ::Wurk::RetrySet.new
      count = case params[:cmd].to_s
              when 'retry'  then set.retry_all
              when 'kill'   then set.kill_all
              when 'delete' then clear_set(set)
              else return render(json: { error: 'unknown action' }, status: :bad_request)
              end
      render json: { ok: true, count: count }
    end

    # --- Scheduled set mutations ---------------------------------------------
    def scheduled_job  = single_entry_action(::Wurk::ScheduledSet.new, SCHEDULED_ACTIONS, params[:cmd])
    def scheduled_bulk = bulk_entry_action(::Wurk::ScheduledSet.new, SCHEDULED_ACTIONS)

    def scheduled_all
      set = ::Wurk::ScheduledSet.new
      count = case params[:cmd].to_s
              when 'delete'       then clear_set(set)
              when 'add_to_queue' then drain_set(set, :add_to_queue)
              else return render(json: { error: 'unknown action' }, status: :bad_request)
              end
      render json: { ok: true, count: count }
    end

    # --- Dead set mutations --------------------------------------------------
    def dead_job  = single_entry_action(::Wurk::DeadSet.new, DEAD_ACTIONS, params[:cmd])
    def dead_bulk = bulk_entry_action(::Wurk::DeadSet.new, DEAD_ACTIONS)

    def dead_all
      set = ::Wurk::DeadSet.new
      count = case params[:cmd].to_s
              when 'retry'  then set.retry_all
              when 'delete' then clear_set(set)
              else return render(json: { error: 'unknown action' }, status: :bad_request)
              end
      render json: { ok: true, count: count }
    end

    def processes
      render json: ::Wurk::ProcessSet.new.map { |p| ::Wurk::Api::Serializers.process_row(p) }
    end

    def batches
      set = ::Wurk::BatchSet.new
      page = ::Wurk::Api::Pagination.window(params)
      rows = ::Wurk::Api::Pagination.slice(set, page) { |status| status.data.transform_keys(&:to_sym) }
      render json: { total: set.size, page: page[:page], count: page[:count], batches: rows }
    end

    def batch
      status = ::Wurk::Batch::Status.new(params[:bid].to_s)
      return render(json: { error: 'unknown batch' }, status: :not_found) unless status.exists?

      render json: status.data.transform_keys(&:to_sym)
    rescue ::ArgumentError
      render json: { error: 'unknown batch' }, status: :not_found
    end

    def limiters
      names = ::Wurk::Web::Enterprise::Limits.list(filter: params[:substr])
      page = ::Wurk::Api::Pagination.window(params)
      render json: { total: names.size, page: page[:page], count: page[:count], limiters: limiter_rows(names, page) }
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

    # Cluster-total throughput/failures time-series for the dashboard charts.
    # `:bucket` is 1m/5m/1h; `?window=24h` (s/m/h/d suffix) is clamped to the
    # bucket's retention. Recharts-ready array under `series`.
    def history
      window = parse_window(params[:window])
      series = ::Wurk::Web::Enterprise::Historical.history(params[:bucket].to_s, window: window)
      render json: { bucket: params[:bucket].to_s, window: window, series: series.map { |row| ::Wurk::Api::Serializers.history_point(row) } }
    rescue ::ArgumentError => e
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

    # Resolves a single entry by "<score>|<jid>" key and applies a whitelisted
    # action. 400 on an unknown action, 404 when the key matches nothing (e.g.
    # the entry was already retried/deleted from another tab).
    def single_entry_action(set, actions, cmd)
      method = actions[cmd.to_s]
      return render(json: { error: 'unknown action' }, status: :bad_request) unless method

      entries = entries_for(set, [params[:key]])
      return render(json: { error: 'unknown job' }, status: :not_found) if entries.empty?

      entries.each { |entry| entry.public_send(method) }
      render json: { ok: true, count: entries.size }
    end

    # Bulk variant: `keys[]` + a single `cmd` applied to every resolved entry.
    def bulk_entry_action(set, actions)
      method = actions[params[:cmd].to_s]
      return render(json: { error: 'unknown action' }, status: :bad_request) unless method

      count = 0
      keys = Array(params[:keys]).map(&:to_s).uniq
      entries_for(set, keys).each do |entry|
        entry.public_send(method)
        count += 1
      end
      render json: { ok: true, count: count }
    end

    # Maps "<score>|<jid>" keys to live SortedEntry objects via score-bracketed
    # fetch (exact float match, narrowed by jid) — avoids depending on float→
    # string round-tripping between JS and Ruby. Skips malformed/empty keys.
    def entries_for(set, keys)
      keys.flat_map do |key|
        score, jid = key.to_s.split('|', 2)
        next [] if jid.nil? || jid.empty?

        set.fetch(score.to_f, jid)
      end
    end

    # UNLINKs the whole set, returning the count removed (read before clearing
    # so the response reports what was deleted).
    def clear_set(set)
      total = set.size
      set.clear
      total
    end

    # Drains a set by applying `method` to every entry until empty. Used for
    # scheduled "add to queue all", where each call removes the entry and would
    # otherwise shift the paged iterator's indices mid-scan.
    def drain_set(set, method)
      count = 0
      until set.size.zero?
        set.each do |entry|
          entry.public_send(method)
          count += 1
        end
      end
      count
    end

    def render_sorted_set(set)
      page = ::Wurk::Api::Pagination.window(params)
      total = set.size
      entries = ::Wurk::Api::Pagination.slice(set, page) { |entry| ::Wurk::Api::Serializers.sorted_entry(entry) }
      render json: { total: total, page: page[:page], count: page[:count], entries: entries }
    end

    # substr is already applied by Limits.list (matches on name), so slice the
    # filtered names directly — only the page's rows pay the per-limiter Redis
    # reads in limiter_row (which folds in live status).
    def limiter_rows(names, page)
      (names.slice(page[:page] * page[:count], page[:count]) || []).map do |name|
        ::Wurk::Api::Serializers.limiter_row(name, limiter_meta(name))
      end
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
    # `?window=24h` → seconds. Accepts an s/m/h/d suffix (bare number = seconds).
    # Falls back to 24h on a missing or unparseable value; the Query layer
    # clamps the result to the bucket's retention.
    def parse_window(raw)
      match = raw.to_s.strip.downcase.match(/\A(\d+)([smhd]?)\z/)
      return DEFAULT_HISTORY_WINDOW unless match

      Integer(match[1]) * HISTORY_WINDOW_UNITS.fetch(match[2].empty? ? 's' : match[2])
    end

    def metrics_window(params)
      pagination = ::Wurk::Api::Pagination
      minutes = pagination.clamp_int(params[:minutes], 1, ::Wurk::Metrics::Query::MAX_MINUTES, 60) if params[:minutes]
      hours   = pagination.clamp_int(params[:hours],   1, ::Wurk::Metrics::Query::MAX_HOURS,   24) if params[:hours]
      minutes ||= 60 if hours.nil?
      [minutes, hours]
    end
  end
end
