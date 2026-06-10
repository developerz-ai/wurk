# frozen_string_literal: true

require_relative 'component'
require_relative 'stats'
require_relative 'metrics/statsd'

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
  # cluster `dear-leader` lock so exactly one process emits per cluster. No-op
  # when no dogstatsd client is configured (nothing to emit to).
  #
  # Aliased as `Sidekiq::History` (drop-in contract).
  # Spec: docs/target/sidekiq-ent.md §5.1–§5.2.
  class History
    include Component

    def initialize(config)
      @config = config
      @interval = config.history_interval
      @collector = config.history_collector
      @done = false
      @mutex = ::Mutex.new
      @sleeper = ::ConditionVariable.new
      @thread = nil
    end

    def start
      @thread ||= safe_thread('history-snapshot') do # rubocop:disable Naming/MemoizedInstanceVariableName
        wait
        until @done
          tick
          wait
        end
      end
    end

    def terminate
      @mutex.synchronize do
        @done = true
        @sleeper.signal
      end
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
    def snapshot
      client = Wurk::Metrics::Statsd.client
      return if client.nil?

      @collector ? @collector.call(client) : default_snapshot(client)
      nil
    end

    private

    # §5.2 default gauge set. Names carry the `sidekiq.` prefix so a dashboard
    # built for Sidekiq Ent reads them unchanged.
    def default_snapshot(client)
      stats = Wurk::Stats.new
      client.gauge('sidekiq.processed', stats.processed)
      client.gauge('sidekiq.failures',  stats.failed)
      client.gauge('sidekiq.enqueued',  stats.enqueued)
      client.gauge('sidekiq.retries',   stats.retry_size)
      client.gauge('sidekiq.dead',      stats.dead_size)
      client.gauge('sidekiq.scheduled', stats.scheduled_size)
      client.gauge('sidekiq.busy',      stats.workers_size)
    end

    def wait
      @mutex.synchronize do
        @sleeper.wait(@mutex, @interval) unless @done
      end
    end
  end
end
