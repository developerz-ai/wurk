# frozen_string_literal: true

module Wurk
  module Metrics
    # Pro parity (§9): emits per-job timing + counters to a statsd / dogstatsd
    # client. The client itself is plumbed in by the host app via:
    #
    #   Wurk.configure_server do |config|
    #     config.dogstatsd = -> { Datadog::Statsd.new('metrics.example.com', 8125) }
    #     config.server_middleware { |chain| chain.add Wurk::Metrics::Statsd }
    #   end
    #
    # The `dogstatsd` accessor is a *callable* — invoked once per process,
    # memoized — so the client is built lazily AFTER fork. Sharing a UDP
    # socket across forks is fine, but `Datadog::Statsd` keeps thread-locals
    # that must be initialized inside the child.
    #
    # Per-job tuning via `Statsd.options = ->(klass, job, queue) { {tags:, sample_rate:} }`.
    # Default options: tags `["worker:<klass>", "queue:<q>"]`, sample_rate 1.0.
    # The `dd_rate` job option, when present, overrides sample_rate.
    #
    # Metric naming follows Sidekiq Pro 8+: every metric prefixed `sidekiq.`
    # (the prefix is hardcoded, not configurable — third-party dashboards
    # built for Sidekiq Pro work unchanged).
    #
    # `Statsd.increment(metric, tags:)` is the class-level fast path used by
    # other Wurk components (Buffered client, Expiry middleware, super_fetch
    # recovery, Batch lifecycle). No-op when no client is configured so
    # callers never have to guard.
    #
    # Spec: docs/target/sidekiq-pro.md §9.
    class Statsd
      include Wurk::Middleware::ServerMiddleware

      METRIC_PREFIX = 'sidekiq.'
      DEFAULT_SAMPLE_RATE = 1.0

      class << self
        attr_accessor :options

        # Counter shortcut used across the codebase. Tags are forwarded as
        # given — caller's job to namespace them (`"class:Foo"`, `"queue:bar"`).
        # No-op when no client is wired up.
        def increment(metric, tags: nil, sample_rate: DEFAULT_SAMPLE_RATE)
          client = self.client
          return nil unless client

          opts = sample_rate_kw(sample_rate)
          opts[:tags] = tags if tags
          client.increment("#{METRIC_PREFIX}#{metric}", **opts)
          nil
        rescue StandardError => e
          handle_error(e)
          nil
        end

        def gauge(metric, value, tags: nil, sample_rate: DEFAULT_SAMPLE_RATE)
          client = self.client
          return nil unless client

          opts = sample_rate_kw(sample_rate)
          opts[:tags] = tags if tags
          client.gauge("#{METRIC_PREFIX}#{metric}", value, **opts)
          nil
        rescue StandardError => e
          handle_error(e)
          nil
        end

        # Distribution send. Some statsd clients lack `distribution` (vanilla
        # statsd-ruby, for example) — fall back to `histogram` so the metric
        # still lands somewhere. `dogstatsd-ruby` always has `distribution`.
        def distribution(metric, value, tags: nil, sample_rate: DEFAULT_SAMPLE_RATE)
          client = self.client
          return nil unless client

          opts = sample_rate_kw(sample_rate)
          opts[:tags] = tags if tags
          name = "#{METRIC_PREFIX}#{metric}"
          if client.respond_to?(:distribution)
            client.distribution(name, value, **opts)
          elsif client.respond_to?(:histogram)
            client.histogram(name, value, **opts)
          end
          nil
        rescue StandardError => e
          handle_error(e)
          nil
        end

        # Resolves the live client: invokes the configured `dogstatsd` proc
        # exactly once per process and memoizes. Returns nil when no proc
        # is configured, so callers get a clean no-op without raising.
        def client
          return @client if defined?(@client) && !@client.nil?

          builder = Wurk.configuration.respond_to?(:dogstatsd) ? Wurk.configuration.dogstatsd : nil
          return nil if builder.nil?

          @client = builder.respond_to?(:call) ? builder.call : builder
        end

        # Test/lifecycle hook. Reset between specs and after fork so the
        # parent's socket doesn't bleed into children.
        def reset!
          @client = nil
        end

        private

        def sample_rate_kw(rate)
          rate == DEFAULT_SAMPLE_RATE ? {} : { sample_rate: rate }
        end

        def handle_error(err)
          Wurk.configuration.handle_exception(err, context: 'Wurk::Metrics::Statsd')
        end
      end

      def call(_worker, job, queue) # rubocop:disable Metrics/AbcSize
        client = safe_client
        return yield if client.nil?

        klass = job['class']
        opts  = per_job_options(klass, job, queue)
        tags  = opts[:tags]
        rate  = opts.fetch(:sample_rate, DEFAULT_SAMPLE_RATE)

        emit(:increment, 'jobs.count', tags: tags, sample_rate: rate)
        started = monotonic_ms
        success = false
        begin
          yield
          success = true
        ensure
          duration = monotonic_ms - started
          # Metrics are best-effort: an emit failure mid-finalize must not
          # corrupt the job result the caller already produced.
          begin
            finalize(success, duration, tags: tags, sample_rate: rate)
          rescue StandardError => e
            self.class.send(:handle_error, e)
          end
        end
      end

      private

      # Wraps `self.class.client` so a misconfigured builder proc never turns
      # a metrics-init failure into a job failure. Returns nil on error (the
      # caller falls through to a plain `yield`).
      def safe_client
        self.class.client
      rescue StandardError => e
        self.class.send(:handle_error, e)
        nil
      end

      # Per-spec §9.2: caller-supplied proc may override tags / sample_rate
      # on a per-job basis. The job's own `dd_rate` field, when present,
      # always wins — it's the per-push override hinted in §8.
      def per_job_options(klass, job, queue)
        base = { tags: default_tags(klass, queue), sample_rate: DEFAULT_SAMPLE_RATE }
        proc = self.class.options
        if proc.respond_to?(:call)
          custom = proc.call(klass, job, queue)
          base = base.merge(custom) if custom.is_a?(Hash)
        end
        base[:sample_rate] = job['dd_rate'].to_f if job.key?('dd_rate')
        base
      end

      def default_tags(klass, queue)
        ["worker:#{klass}", "queue:#{queue}"]
      end

      def finalize(success, duration, tags:, sample_rate:)
        metric = success ? 'jobs.success' : 'jobs.failure'
        emit(:increment, metric, tags: tags, sample_rate: sample_rate)
        emit(:gauge, 'jobs.perform', duration, tags: tags, sample_rate: sample_rate)
        emit(:distribution, 'jobs.perform_dist', duration, tags: tags, sample_rate: sample_rate)
      end

      def emit(kind, metric, value = nil, tags:, sample_rate:)
        case kind
        when :increment    then self.class.increment(metric, tags: tags, sample_rate: sample_rate)
        when :gauge        then self.class.gauge(metric, value, tags: tags, sample_rate: sample_rate)
        when :distribution then self.class.distribution(metric, value, tags: tags, sample_rate: sample_rate)
        end
      end

      def monotonic_ms
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :float_millisecond)
      end
    end
  end
end
