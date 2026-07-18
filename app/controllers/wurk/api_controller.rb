# frozen_string_literal: true

require_relative 'api/serializers'
require_relative 'api/pagination'
require 'wurk/web'

module Wurk
  # JSON APIs consumed by the SolidJS SPA. Action methods stay thin; mapping to
  # the wire shape lives in `Wurk::Api::Serializers`, and pagination lives in
  # `Wurk::Api::Pagination`. SSE lives in #stream.
  #
  # Wire-compat: every payload field reads from the canonical Wurk inspector
  # objects (Stats, Queue, RetrySet, ScheduledSet, DeadSet, ProcessSet,
  # BatchSet, Cron::LoopSet) so dashboards stay aligned with the Redis schema
  # in `docs/target/sidekiq-{free,pro,ent}.md`.
  class ApiController < ApplicationController
    include ActionController::Live
    # The SPA is a token-less JSON client; SameOriginGuard supplies Sidekiq's
    # same-origin CSRF defense (spec §25.1) so every mutating endpoint is
    # protected — GET reads (incl. #stream SSE) stay reachable.
    include SameOriginGuard
    # Bounds concurrent SSE streams per process (503 past the cap) so stale
    # dashboard tabs can't pin every Puma thread. Provides #with_stream_slot.
    include StreamConcurrencyGuard
    # Owns the #stream action's tick loop (headers, cadence, tear-down).
    include SseStreaming

    STREAM_TICK_SECONDS = 2.0
    STREAM_MAX_DURATION = 120.0
    # Positive floor for `?tick=`: a zero/negative tick would `sleep 0` the SSE
    # loop into a tight Redis-read/write spin (Live runs it in a spawned thread)
    # for up to STREAM_MAX_DURATION. Clamp before it reaches drive_stream.
    STREAM_MIN_TICK_SECONDS = 0.1

    HISTORY_WINDOW_UNITS = { 's' => 1, 'm' => 60, 'h' => 3600, 'd' => 86_400 }.freeze
    DEFAULT_HISTORY_WINDOW = 24 * 3600

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
      render json: {
        version: ::Wurk::VERSION,
        read_only: config.read_only? || !mutations_authorized?(config),
        read_only_message: config.read_only_message,
        custom_tabs: config.custom_tabs
      }
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

    # Pause/unpause a queue (Pro §6, §10.1). Idempotent; returns the resulting
    # state so the SPA can update its toggle without a refetch round-trip.
    def pause_queue
      ::Wurk::Queue.new(params[:name].to_s).pause!
      render json: { ok: true, paused: true }
    end

    def unpause_queue
      ::Wurk::Queue.new(params[:name].to_s).unpause!
      render json: { ok: true, paused: false }
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
      set = ::Wurk::ProcessSet.new
      leader_identity = set.leader
      render json: set.map { |p| ::Wurk::Api::Serializers.process_row(p, leader_identity: leader_identity) }
    end

    # Currently-executing jobs across the cluster (WorkSet), oldest first.
    # The Busy page's process-detail modal filters client-side by process_id.
    def workers
      render json: ::Wurk::WorkSet.new.map { |pid, tid, work| ::Wurk::Api::Serializers.work_row(pid, tid, work) }
    end

    # Busy-page controls: SIGTSTP (quiet — drop fetch, drain in-flight) and
    # SIGTERM (stop — graceful shutdown). Both are async; the target notices on
    # its next heartbeat (≤10s). `identity` absent or "all" signals every live
    # process.
    def quiet_process = signal_processes(:quiet!)
    def stop_process  = signal_processes(:stop!)

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

    # Ent §5.3 Historical snapshots from the capped `history:metrics` stream.
    # `?limit=N` (default 1000) most-recent points, oldest→newest, each
    # `{at:, processed:, failures:, …}`. Fields are read generically so a
    # migrated Sidekiq Ent stream renders as-is.
    def history_snapshots
      limit = ::Wurk::Api::Pagination.clamp_int(
        params[:limit], 1, ::Wurk::History::STREAM_CAP, ::Wurk::History::STREAM_DEFAULT_LIMIT
      )
      render json: { snapshots: ::Wurk::Web::Enterprise::Historical.snapshots(limit: limit) }
    end

    # Per-queue size/latency gauge time-series for the Metrics/Historical tab.
    # `:bucket` is 1m/5m/1h; `?window=24h` (s/m/h/d) is clamped to the bucket's
    # retention; optional `?queue=<name>` narrows to one queue. Each queue's
    # `points` are Recharts-ready.
    def queue_history
      window = parse_window(params[:window])
      queues = params[:queue].present? ? [params[:queue].to_s] : nil
      series = ::Wurk::Web::Enterprise::Historical.queue_history(params[:bucket].to_s, window: window, queues: queues)
      render json: {
        bucket: params[:bucket].to_s,
        window: window,
        queues: series.map { |row| ::Wurk::Api::Serializers.queue_history_series(row) }
      }
    rescue ::ArgumentError => e
      render json: { error: e.message }, status: :bad_request
    end

    def search
      substr = params[:substr].to_s
      return render(json: { substr: substr, total: 0, hits: [], truncated: false }) if substr.empty?

      search = ::Wurk::Web::Search.new(substr, kinds: parse_search_kinds(params), limit: parse_search_limit(params))
      hits = search.to_a
      render json: { substr: substr, total: hits.size, hits: hits, truncated: search.truncated? }
    end

    # Profiles list (v8.0+). The SPA links each row to /profiles/:key (view)
    # and /profiles/:key/data (raw blob). Newest first.
    def profiles
      records = ::Wurk::ProfileSet.new.map { |rec| ::Wurk::Api::Serializers.profile_record(rec) }
      render json: records.sort_by { |r| -(r[:started_at] || 0) }
    end

    # SSE: one `event: stats` per tick with a fresh Stats snapshot. Caps at
    # `STREAM_MAX_DURATION` so a stale browser tab can't tie a Rails worker
    # forever — the client reconnects automatically when the stream closes.
    # Bounded per process by StreamConcurrencyGuard (503 + Retry-After past the
    # cap) so a burst of tabs can't pin every Puma thread.
    #
    # `?max_duration=` and `?tick=` are test/debug knobs; the SPA never sets
    # them. `?max_duration=0` emits one tick and closes.
    def stream
      with_stream_slot do
        stream_headers!
        clamp = ::Wurk::Api::Pagination.method(:clamp_float)
        tick = clamp.call(params[:tick], STREAM_MIN_TICK_SECONDS, STREAM_TICK_SECONDS, STREAM_TICK_SECONDS)
        max_dur = clamp.call(params[:max_duration], 0.0, STREAM_MAX_DURATION, STREAM_MAX_DURATION)
        sse = ::ActionController::Live::SSE.new(response.stream, retry: (STREAM_TICK_SECONDS * 1000).to_i)
        drive_stream(sse, tick, max_dur)
      end
    end

    private

    # Engine-relative path probed as a representative mutation. Must be a real
    # mutating route (POST /api/retries — bulk retry/delete/kill) so that a
    # path-sensitive hook resolves it the same way the Authorization middleware
    # will resolve the actual mutation. Probing `request.path_info` (which here
    # is the GET /api/meta path) would let such a hook allow the probe while
    # still 403ing real mutations, reviving the "button shows, then 403s" gap.
    MUTATION_PROBE_PATH = '/api/retries'

    # Per-request read-only signal for the SPA. When a registered authorization
    # hook would reject a *mutating* request for this user (e.g. a viewer role
    # that may GET but not retry/kill), report `read_only` so the SPA hides the
    # destructive actions — the Authorization middleware already 403s the
    # mutation itself, this just stops the buttons from showing. With no hook
    # registered, `authorized?` is always true, so this is a no-op and the flag
    # keeps reflecting the global read-only mode. Probes POST on a canonical
    # mutating path (SAFE_METHODS are GET/HEAD/OPTIONS) so a path-sensitive hook
    # answers for a real mutation, not the GET /api/meta request carrying it.
    def mutations_authorized?(config)
      config.authorized?(request.env, 'POST', MUTATION_PROBE_PATH)
    end

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

    # Sends `method` (:quiet! / :stop!) to one process by identity, or to every
    # live process when identity is blank/"all". Embedded processes are skipped
    # (they raise on quiet!/stop! — there's no separate process to signal). 404s
    # when a named identity isn't in the live set.
    def signal_processes(method)
      identity = params[:identity].to_s
      if identity.empty? || identity == 'all'
        count = ::Wurk::ProcessSet.new.reject(&:embedded?).each { |p| p.public_send(method) }.size
        return render(json: { ok: true, count: count })
      end

      process = ::Wurk::ProcessSet[identity]
      return render(json: { error: 'unknown process' }, status: :not_found) unless process

      process.public_send(method) unless process.embedded?
      render json: { ok: true, count: process.embedded? ? 0 : 1 }
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
        ::Wurk::Api::Serializers.limiter_row(name, ::Wurk::Web::Enterprise::Limits.metadata(name))
      end
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
