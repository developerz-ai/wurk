# frozen_string_literal: true

module Wurk
  module Metrics
    # Ent feature parity: historical time-series stored in Redis,
    # bucketed minutely / hourly / daily. Powers the metrics pane.
    class History
      def record(job_class, duration_ms, status:); end
      def query(job_class:, from:, to:); end
    end
  end
end
