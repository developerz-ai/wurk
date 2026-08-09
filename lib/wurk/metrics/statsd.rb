# frozen_string_literal: true

require_relative '../job'

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

      # Unresolved state of the {.client} memo, distinct from a resolved nil.
      UNSET = :unset
      private_constant :UNSET

      # Seeded in the class body (not `class << self`, where `self` is the
      # singleton class) so {.client} is a bare ivar read with no `defined?`
      # guard on the hot path.
      @client = UNSET

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
        #
        # The *unconfigured* answer is memoized too, which is what makes the
        # no-client path free: Client#emit_enqueued asks once per payload, so
        # re-reading `Wurk.configuration` here would cost a config lookup per
        # job on every bulk push. Both invalidation points call {.reset!}.
        def client
          memo = @client
          return memo unless UNSET.equal?(memo)

          builder = Wurk.configuration.respond_to?(:dogstatsd) ? Wurk.configuration.dogstatsd : nil
          @client = builder.respond_to?(:call) ? builder.call : builder
        end

        # {.client} without the raise: a builder proc that blows up is reported
        # through the error handler and treated as "no client", so misconfigured
        # metrics can never fail the work they were measuring. Callers on a
        # hot path use this to skip building anything the emit would drop.
        def safe_client
          client
        rescue StandardError => e
          handle_error(e)
          nil
        end

        # Test/lifecycle hook. Reset between specs, after fork so the parent's
        # socket doesn't bleed into children, and on every `config.dogstatsd=`
        # — a memoized nil would otherwise hide a client configured later.
        def reset!
          @client = UNSET
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
        return yield if self.class.safe_client.nil?

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
        rescue Wurk::Job::Interrupted, Wurk::Job::DeadlineExceeded
          # Same arm, same reasons as Metrics::History#call (#394): a cooperative
          # interruption passes through here before InterruptHandler turns it
          # into a JobRetry::Skip, and a job cut by its deadline passes through
          # before Middleware::Expiry books it `expired` — both sit outside this
          # middleware, and without this arm either one emits `jobs.failure`.
          # Pro's statsd emitter is closed source, so the oracle is the free
          # ExecutionTracker plus the rule that the two Wurk emitters must never
          # classify one event differently. Signed off in
          # docs/plans/2026/08/07/101-beyond-sidekiq/00-semantics-signoff.md §1.
          success = true
          raise
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

  module Middleware
    # Sidekiq Pro documents the statsd server middleware as
    # `Sidekiq::Middleware::Server::Statsd` (spec §9.1) — the drop-in snippet is
    # `require "sidekiq/middleware/server/statsd"; chain.add Sidekiq::Middleware::Server::Statsd`.
    # Expose that namespace pointing at our implementation. `Sidekiq::Middleware`
    # aliases `Wurk::Middleware`, so this makes the Sidekiq constant resolve too.
    module Server
      Statsd = Wurk::Metrics::Statsd
    end
  end
end
