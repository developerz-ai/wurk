# frozen_string_literal: true

module Wurk
  module Metrics
    # This process's live RedisPools by name, for the `/metrics` pool gauges.
    # A pool joins when built and leaves on RedisPool#disconnect!; a later pool
    # with the same name replaces the earlier one.
    module PoolRegistry
      @lock = ::Mutex.new
      @pools = {}

      class << self
        def register(pool)
          @lock.synchronize { @pools[pool.name] = pool }
        end

        def deregister(pool)
          @lock.synchronize { @pools.delete(pool.name) if @pools[pool.name].equal?(pool) }
        end

        def live
          @lock.synchronize { @pools.values }
        end
      end
    end
  end
end
