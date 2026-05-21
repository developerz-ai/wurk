# frozen_string_literal: true

module Wurk
  module Metrics
    # Pro feature parity: per-job timing + counters to a statsd endpoint.
    class Statsd
      def initialize(host:, port: 8125, prefix: 'wurk'); end
      def record(job_class, duration_ms, status:); end

      # Class-level metric increment. Hook for the dogstatsd integration
      # (docs/target/sidekiq-pro.md §9.1) that lands with the Statsd task.
      # No-op when no client is configured so callers in Wurk::Client::Buffered
      # and other Pro features don't crash in test/dev environments.
      def self.increment(_metric, tags: nil) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end
    end
  end
end
