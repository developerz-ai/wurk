# frozen_string_literal: true

module Wurk
  # Per-process cap on concurrent SSE streams. ActionController::Live pins one
  # Puma thread for every open `/api/stream`; without a bound, a burst of stale
  # browser tabs could hold every thread and starve the JSON API. Past the cap
  # we 503 with Retry-After — the SPA's EventSource reconnects (and its polling
  # fallback honors Retry-After) once a slot frees. Per-process is the right
  # scope: it's this process's own thread pool we're protecting.
  #
  # Slots are held as thread references rather than tallied in a counter so the
  # cap can heal itself. A stream whose thread is killed mid-flight never
  # reaches the `ensure` below (Puma hard-reaps worker threads past
  # `force_shutdown_after`, and a thread killed inside an uninterruptible read
  # can skip its ensure), which a counter would record as a slot held by nobody
  # — ten of those and `/api/stream` 503s for the life of the process. A dead
  # holder is instead evicted by the next acquire.
  module StreamConcurrencyGuard
    extend ActiveSupport::Concern

    MAX_CONCURRENT_STREAMS = 10
    RETRY_AFTER_SECONDS = 3

    @holders = []
    @lock = Mutex.new

    class << self
      # Reserve a stream slot for the calling thread; false when the cap is
      # already reached by threads that are still alive.
      def acquire
        @lock.synchronize do
          @holders.keep_if(&:alive?)
          return false if @holders.size >= MAX_CONCURRENT_STREAMS

          @holders << Thread.current
          true
        end
      end

      # Drops one slot held by the calling thread. Acquire and release always
      # bracket a single block on one thread (`#with_stream_slot`), so a call
      # from a thread holding nothing is a no-op rather than a slot taken away
      # from whoever is actually streaming.
      def release
        @lock.synchronize do
          index = @holders.rindex(Thread.current)
          @holders.delete_at(index) if index
        end
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
