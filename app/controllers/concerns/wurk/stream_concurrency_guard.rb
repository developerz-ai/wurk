# frozen_string_literal: true

module Wurk
  # Per-process cap on concurrent SSE streams. ActionController::Live pins one
  # Puma thread for every open `/api/stream`; without a bound, a burst of stale
  # browser tabs could hold every thread and starve the JSON API. Past the cap
  # we 503 with Retry-After — the SPA's EventSource reconnects (and its polling
  # fallback honors Retry-After) once a slot frees. Per-process is the right
  # scope: it's this process's own thread pool we're protecting.
  module StreamConcurrencyGuard
    extend ActiveSupport::Concern

    MAX_CONCURRENT_STREAMS = 10
    RETRY_AFTER_SECONDS = 3

    @open = 0
    @lock = Mutex.new

    class << self
      # Reserve a stream slot; false when the cap is already reached.
      def acquire
        @lock.synchronize do
          return false if @open >= MAX_CONCURRENT_STREAMS

          @open += 1
          true
        end
      end

      def release
        @lock.synchronize { @open -= 1 if @open.positive? }
      end
    end

    private

    # Runs the SSE body only while holding a slot, releasing it however the
    # stream ends (client disconnect, cap-duration, error). 503 + Retry-After
    # past the cap instead of tying up a thread on an unservable request.
    def with_stream_slot
      unless StreamConcurrencyGuard.acquire
        response.headers['Retry-After'] = RETRY_AFTER_SECONDS.to_s
        return head :service_unavailable
      end

      begin
        yield
      ensure
        StreamConcurrencyGuard.release
      end
    end
  end
end
