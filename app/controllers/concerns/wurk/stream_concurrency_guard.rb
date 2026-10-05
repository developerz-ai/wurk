# frozen_string_literal: true

module Wurk
  # Per-process cap on concurrent SSE streams. ActionController::Live pins one
  # server thread for every open `/api/stream`; the cap is half the server's
  # request threads (at least one) so streams can never take the threads the
  # host app's own requests need. A fixed cap of 10 sat above Rails' default of
  # 3 Puma threads, so three dashboard tabs hung the host app for the stream's
  # whole lifetime. Past the cap we 503 (Retry-After is set for non-browser
  # clients; EventSource can't read it, so the SPA backs off on its own from 3s,
  # doubling to 30s).
  # Per-process is the right scope: it's this process's own thread pool we're
  # protecting. `config.web.max_streams` overrides the derived cap.
  #
  # Slots are held as thread references rather than tallied in a counter so the
  # cap can heal itself. A stream whose thread is killed mid-flight never
  # reaches the `ensure` below (Puma hard-reaps worker threads past
  # `force_shutdown_after`, and a thread killed inside an uninterruptible read
  # can skip its ensure), which a counter would record as a slot held by nobody
  # — a cap's worth of those and `/api/stream` 503s for the life of the
  # process. A dead holder is instead evicted by the next acquire.
  module StreamConcurrencyGuard
    extend ActiveSupport::Concern

    RETRY_AFTER_SECONDS = 3
    # Rails' generated puma.rb default (`RAILS_MAX_THREADS || 3`), used when
    # neither Puma nor the environment says how many threads serve requests.
    DEFAULT_SERVER_THREADS = 3

    @holders = []
    @lock = Mutex.new

    class << self
      def max_streams
        configured = ::Wurk::Web.config.max_streams
        return Integer(configured) if configured

        [server_threads / 2, 1].max
      end

      # Reserve a stream slot for the calling thread; false when the cap is
      # already reached by threads that are still alive.
      def acquire
        @lock.synchronize do
          @holders.keep_if(&:alive?)
          return false if @holders.size >= max_streams

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

      private

      # Puma's own max_threads when it booted through its launcher (`puma`,
      # `rails s`), else RAILS_MAX_THREADS — what the generated puma.rb reads.
      def server_threads
        puma = ::Puma.cli_config&.options&.[](:max_threads) if defined?(::Puma) && ::Puma.respond_to?(:cli_config)
        Integer(puma || ENV.fetch('RAILS_MAX_THREADS', DEFAULT_SERVER_THREADS))
      rescue ::ArgumentError, ::TypeError
        DEFAULT_SERVER_THREADS
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
