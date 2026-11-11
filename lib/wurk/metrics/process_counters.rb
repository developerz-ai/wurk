# frozen_string_literal: true

module Wurk
  module Metrics
    # In-memory counters for events with no Redis key of their own, exposed by
    # Metrics::Prometheus. Per process: under a swarm, a scrape sees only the
    # child that owns the health port.
    #
    # A labelled series is keyed `[name, label]` and read back with #labelled.
    # #set stores a gauge under the same table.
    module ProcessCounters
      @lock = ::Mutex.new
      @counts = Hash.new(0)

      class << self
        def increment(name, by = 1)
          @lock.synchronize { @counts[name] += by }
        end

        def set(name, value)
          @lock.synchronize { @counts[name] = value }
        end

        def value(name)
          @lock.synchronize { @counts[name] }
        end

        # `{ label => value }` for every `[name, label]` key.
        def labelled(name)
          @lock.synchronize do
            @counts.each_with_object({}) do |(key, value), out|
              out[key[1]] = value if key.is_a?(::Array) && key[0] == name
            end
          end
        end

        def reset!
          @lock.synchronize { @counts.clear }
        end
      end
    end
  end
end
