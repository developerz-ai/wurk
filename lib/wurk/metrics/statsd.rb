# frozen_string_literal: true

module Wurk
  module Metrics
    # Pro feature parity: per-job timing + counters to a statsd endpoint.
    class Statsd
      def initialize(host:, port: 8125, prefix: "wurk"); end
      def record(job_class, duration_ms, status:); end
    end
  end
end
