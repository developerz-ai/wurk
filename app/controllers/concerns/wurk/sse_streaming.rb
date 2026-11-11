# frozen_string_literal: true

module Wurk
  # Drives the `/api/stream` SSE loop (headers, tick cadence, tear-down).
  # Split out of ApiController so the periodic-stats-push mechanics — which
  # don't change per action — stay separate from the request/response mapping
  # ApiController owns.
  module SseStreaming
    extend ActiveSupport::Concern

    # One stats payload per process per TTL, shared by every open stream: ten
    # dashboard tabs ticking every 2s cost one Redis read, not ten. Streams
    # that tick together wait on the lock and take the payload the first one
    # read. Keyed on the pool so a payload read from one Redis never answers
    # for another; a raising read caches nothing.
    class SharedTick
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
    SHARED_TICK = SharedTick.new(1.0)

    private

    def stream_headers!
      response.headers['Content-Type'] = 'text/event-stream'
      response.headers['Cache-Control'] = 'no-cache'
      response.headers['X-Accel-Buffering'] = 'no'
    end

    def drive_stream(sse, tick, max_dur)
      deadline = monotime + max_dur
      loop do
        sse.write(stream_tick_payload, event: 'stats')
        break if monotime >= deadline

        sleep tick
      end
    rescue ::IOError, ::ActionController::Live::ClientDisconnected
      # client closed; nothing to clean up.
    rescue *::Wurk::Configuration::REDIS_ERROR_CLASSES => e
      # Headers are already flushed by the time a tick hits Redis, so the
      # 503 ApplicationController's rescue_from renders for a plain request
      # can't happen here — emit a structured SSE event instead and close;
      # the closed stream is reopened by EventSource after the `retry:`
      # interval and gets a fresh chance at Redis.
      logger.warn("wurk web: stream redis unavailable (#{e.class}: #{e.message})")
      sse.write({ error: 'redis_unavailable' }, event: 'error')
    ensure
      sse.close
    end

    def monotime
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    def stream_tick_payload
      SHARED_TICK.fetch { ::Wurk::Api::Serializers.stats_payload(::Wurk::Stats::Snapshot.new) }
                 .merge(at: ::Time.now.to_f)
    end
  end
end
