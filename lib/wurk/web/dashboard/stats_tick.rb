# frozen_string_literal: true

module Wurk
  class Web
    module Dashboard
      # The payload of one `/api/stream` tick, shared by every open stream in
      # the process under either transport: ten dashboard tabs ticking every
      # 2s cost one Redis read, not ten. Streams that tick together wait on the
      # lock and take the payload the first one read. Keyed on the pool so a
      # payload read from one Redis never answers for another; a raising read
      # caches nothing.
      module StatsTick
        class Cache
          def initialize(ttl)
            @ttl = ttl
            @lock = ::Mutex.new
            clear!
          end

          def fetch
            pool = ::Wurk.redis_pool
            @lock.synchronize do
              now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
              return @payload if @payload && @pool.equal?(pool) && now - @read_at < @ttl

              payload = yield.freeze
              @payload = payload
              @pool = pool
              @read_at = now
              payload
            end
          end

          def clear!
            @lock.synchronize { @payload = @pool = @read_at = nil }
          end
        end

        # Under the 2s tick, so one stream never reads its own previous payload.
        SHARED = Cache.new(1.0)

        def self.payload
          SHARED.fetch { ::Wurk::Api::Serializers.stats_payload(::Wurk::Stats::Snapshot.new) }
                .merge(at: ::Time.now.to_f)
        end
      end
    end
  end
end
