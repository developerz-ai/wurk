# frozen_string_literal: true

module Wurk
  # Drives the `/api/stream` SSE loop (headers, tick cadence, tear-down).
  # Split out of ApiController so the periodic-stats-push mechanics — which
  # don't change per action — stay separate from the request/response mapping
  # ApiController owns.
  module SseStreaming
    extend ActiveSupport::Concern

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
      # the SPA's EventSource reconnects and gets a fresh chance at Redis.
      logger.warn("wurk web: stream redis unavailable (#{e.class}: #{e.message})")
      sse.write({ error: 'redis_unavailable' }, event: 'error')
    ensure
      sse.close
    end

    def monotime
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    def stream_tick_payload
      ::Wurk::Api::Serializers.stats_payload(::Wurk::Stats.new).merge(at: ::Time.now.to_f)
    end
  end
end
