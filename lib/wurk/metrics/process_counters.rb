# frozen_string_literal: true

module Wurk
  module Metrics
    # In-memory counters for events with no Redis key of their own, exposed by
    # Metrics::Prometheus. Per process: under a swarm, a scrape sees only the
    # child that owns the health port.
    module ProcessCounters
      @lock = ::Mutex.new
      @counts = Hash.new(0)

      class << self
        def increment(name, by = 1)
          @lock.synchronize { @counts[name] += by }
        end

        def value(name)
          @lock.synchronize { @counts[name] }
        end

        def reset!
          @lock.synchronize { @counts.clear }
        end
      end
    end
  end
end
