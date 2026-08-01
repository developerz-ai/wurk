# frozen_string_literal: true

require_relative 'component'
require_relative 'keys'
require_relative 'stats'
require_relative 'metrics/statsd'
require_relative 'timer_loop'

module Wurk
  # Sidekiq Enterprise §5 Historical Metrics snapshotter. A leader-gated
  # background thread that, every `config.retain_history` seconds, emits a
  # statsd-shaped snapshot to the configured dogstatsd client — either the
  # default §5.2 gauge set or a user-supplied collector block.
  #
  # Configured in a server block:
  #
  #   Sidekiq.configure_server do |config|
  #     config.dogstatsd = -> { Datadog::Statsd.new('localhost', 8125) }
  #     config.retain_history(30)                      # default §5.2 gauges
  #     # …or a custom collector:
  #     config.retain_history(30) do |s|
  #       Sidekiq::Queue.all.each do |q|
  #         s.gauge("sidekiq.queue.size", q.size, tags: ["queue:#{q.name}"])
  #       end
  #     end
  #   end
  #
  # The block receives the raw dogstatsd client `s` (quacks like
  # `Datadog::Statsd`: gauge/count/histogram/batch) and writes fully-qualified
  # `sidekiq.*` metric names itself, matching Sidekiq Ent. Leader-gated via the
  # cluster `dear-leader` lock so exactly one process emits per cluster.
  #
  # Every snapshot is also appended to the capped Redis stream
  # `history:metrics` (§5.3) — the same key a migrated Sidekiq Ent install
  # uses — so the dashboard's Historical view has a data source independent of
  # any external statsd, and pre-existing Ent stream data renders without
  # rewrite. The stream write happens whenever the snapshotter runs; the
  # dogstatsd emit is skipped only when no client is configured.
  #
  # Aliased as `Sidekiq::History` (drop-in contract).
  # Spec: docs/target/sidekiq-ent.md §5.1–§5.3.
  class History
    include Component

    # Stream field → Stats reader. Single source for both the `history:metrics`
    # stream entry and the default §5.2 statsd gauge set (which prefixes
    # `sidekiq.`). Order is the display order.
    SNAPSHOT_FIELDS = {
      'processed' => :processed,
      'failures' => :failed,
      'enqueued' => :enqueued,
      'retries' => :retry_size,
      'dead' => :dead_size,
      'scheduled' => :scheduled_size,
      'busy' => :workers_size
    }.freeze

    # Approximate cap on retained snapshots (XADD MAXLEN ~). At the default 30s
    # interval this is ~3.5 days of history; older points age out. `~` lets
    # Redis trim in whole macro-nodes, so the actual length can briefly exceed
    # the cap — matching Ent's best-effort retention.
    STREAM_CAP = 10_000
    STREAM_DEFAULT_LIMIT = 1000

    def initialize(config)
      @config = config
      @collector = config.history_collector
      @stream_cap = config[:history_stream_cap] || STREAM_CAP
      @timer = TimerLoop.new(config.history_interval)
      @thread = nil
    end

    def start
      return @thread if @thread

      @timer.reset
      @thread = safe_thread('history-snapshot') { @timer.run { tick } }
    end

    # Blocks until the thread is really gone: the launcher releases the cluster
    # lock immediately after this returns, and a snapshot still in flight would
    # race the next leader's first one.
    #
    # Cleared only on a confirmed join (Thread#join returns nil on timeout): a
    # wedged thread must stay tracked so #start's guard returns it instead of
    # calling @timer.reset, which would un-terminate the loop it is still
    # inside and leave two threads writing the same stream.
    def terminate
      @timer.terminate
      @thread = nil if @thread&.join(TimerLoop::JOIN_TIMEOUT)
    end

    # Leader-gated: only the elected leader emits, so N workers don't each
    # publish the same cluster-wide gauges every interval.
    def tick
      return unless leader?

      snapshot
    rescue StandardError => e
      handle_exception(e, { context: 'history-snapshot' })
    end

    # One snapshot, bypassing the leader gate and the sleep loop. Public so
    # deterministic specs and a manual "snapshot now" can drive it directly.
    # Always appends to the `history:metrics` stream (the dashboard's source);
    # additionally emits to dogstatsd when a client is configured.
    def snapshot
      values = collect_values
      record_stream(values)
      emit_statsd(values)
      nil
    end

    # Most-recent snapshots from the `history:metrics` stream, oldest→newest.
    # Each point is `{ at: <epoch seconds>, <field>: <numeric>, … }`. Fields are
    # read generically, so a migrated Sidekiq Ent install's entries render
    # without rewrite regardless of which fields they carry.
    def self.recent(limit: STREAM_DEFAULT_LIMIT)
      count = limit.to_i.clamp(1, STREAM_CAP)
      entries = Wurk.redis { |c| c.call('XREVRANGE', Keys::HISTORY_METRICS, '+', '-', 'COUNT', count) }
      entries.reverse.map { |entry_id, fields| parse_entry(entry_id, fields) }
    end

    def self.parse_entry(entry_id, fields)
      pairs = fields.is_a?(::Array) ? fields.each_slice(2).to_h : fields
      point = { at: stream_epoch(entry_id) }
      pairs.each { |field, value| point[field.to_sym] = numeric(value) }
      point
    end

    # Redis stream IDs are "<ms>-<seq>"; the ms half is the snapshot time.
    def self.stream_epoch(entry_id)
      entry_id.to_s.split('-', 2).first.to_i / 1000.0
    end

    # Coerce a stream field to Int/Float for charting; leave non-numeric Ent
    # fields (e.g. a label) untouched so nothing is silently dropped.
    def self.numeric(value)
      float = Float(value)
      (float % 1).zero? ? float.to_i : float
    rescue ::ArgumentError, ::TypeError
      value
    end

    private

    def collect_values
      stats = Wurk::Stats.new
      SNAPSHOT_FIELDS.transform_values { |reader| stats.public_send(reader) }
    end

    def record_stream(values)
      fields = values.flat_map { |field, value| [field, value] }
      redis do |c|
        c.call('XADD', Keys::HISTORY_METRICS, 'MAXLEN', '~', @stream_cap, '*', *fields)
      end
    end

    # §5.2 default gauge set carries the `sidekiq.` prefix so a dashboard built
    # for Sidekiq Ent reads it unchanged. A custom collector replaces it.
    def emit_statsd(values)
      client = Wurk::Metrics::Statsd.client
      return if client.nil?
      return @collector.call(client) if @collector

      values.each { |field, value| client.gauge("sidekiq.#{field}", value) }
    end
  end
end
