# frozen_string_literal: true

require_relative 'queues'
require_relative 'middleware/chain'

module Wurk
  # Sidekiq::Testing-compatible test harness (aliased to Sidekiq::Testing).
  # Three modes control how `Wurk::Client#raw_push` behaves:
  #
  #   :disable — real Redis push (the default; production behavior)
  #   :fake    — payloads collected in the in-memory Wurk::Queues store
  #   :inline  — jobs executed synchronously the instant they're pushed
  #
  # A block form switches the mode for the duration of the block on the current
  # thread only (`fake! { ... }`); the no-block form sets it process-globally.
  #
  # Spec: docs/target/sidekiq-free.md §24.
  module Testing
    class TestModeAlreadySetError < ::RuntimeError; end
    # Raised by `Worker.perform_one` / `drain` when no fake job is available.
    class EmptyQueueError < ::RuntimeError; end

    THREAD_KEY = :__wurk_testing_mode

    class << self
      def disable!(&) = __set_test_mode(:disable, &)
      def fake!(&)    = __set_test_mode(:fake, &)
      def inline!(&)  = __set_test_mode(:inline, &)

      def disabled? = mode == :disable
      def enabled?  = !disabled?
      def fake?     = mode == :fake
      def inline?   = mode == :inline

      # Thread-local override (set by a block) wins over the global mode, so a
      # `fake! { ... }` block is isolated to the calling thread.
      def mode
        ::Thread.current[THREAD_KEY] || @mode || :disable
      end

      # Block → thread-local for the block's duration; no block → global.
      # Nesting block forms (`fake! { inline! { ... } }`) is rejected, matching
      # Sidekiq 8.
      def __set_test_mode(new_mode, &block)
        return @mode = new_mode unless block

        if ::Thread.current[THREAD_KEY]
          raise TestModeAlreadySetError, 'Nested Sidekiq::Testing block modes are not allowed'
        end

        ::Thread.current[THREAD_KEY] = new_mode
        begin
          block.call
        ensure
          ::Thread.current[THREAD_KEY] = nil
        end
      end

      # In-process server-middleware chain used by `:inline` mode. Empty by
      # default — configure with `Sidekiq::Testing.server_middleware { |c| ... }`.
      # Deliberately NOT the globally configured chain: Sidekiq builds a fresh
      # empty chain here too, and inline tests that suddenly ran batch/limiter/
      # metrics middleware would diverge from a migrated suite's expectations.
      # `perform_inline` is the explicit-execution path and does use the real
      # chains (see Wurk::Worker::Setter#perform_inline).
      def server_middleware
        @server_middleware ||= ::Wurk::Middleware::Chain.new(::Wurk.configuration)
        yield @server_middleware if block_given?
        @server_middleware
      end

      # `require "sidekiq/testing"` flips Sidekiq into fake mode as a side
      # effect; a migrated suite that never calls `fake!` would otherwise push
      # into real Redis while every `MyJob.jobs` assertion came back empty.
      # Deprecated in Sidekiq 8 in favour of `Sidekiq.testing!` — hence the
      # warning. A mode already chosen (globally or for this thread) means the
      # suite is explicit: don't override it, and don't warn again.
      def deprecated_require!
        return if ::Thread.current[THREAD_KEY] || @mode

        ::Kernel.warn '⛔️ `require "sidekiq/testing"` is deprecated and will be removed in Sidekiq 9.0. ' \
                      'Use `Sidekiq.testing!(:fake)` instead.'
        fake!
      end

      # --- push hooks invoked by Wurk::Client#raw_push -------------------

      # Route a push through the active test mode (only called when enabled?).
      def dispatch_push(payloads)
        inline? ? inline_push(payloads) : fake_push(payloads)
      end

      # Collect payloads into the in-memory store. `enqueued_at` is stamped now
      # unless the job is scheduled (`at`), mirroring the real client.
      def fake_push(payloads)
        now = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
        payloads.each do |payload|
          payload['enqueued_at'] = now unless payload['at']
          ::Wurk::Queues.push(payload['queue'], payload['class'], payload)
        end
        payloads.last['jid']
      end

      # Execute each payload immediately through the inline server chain.
      def inline_push(payloads)
        payloads.each { |payload| ::Object.const_get(payload['class'].to_s).process_job(payload) }
        payloads.last['jid']
      end

      # Run every fake job across all classes until the store is empty.
      def drain_all
        count = 0
        while (job = ::Wurk::Queues.shift_any)
          ::Object.const_get(job['class'].to_s).process_job(job)
          count += 1
        end
        count
      end
    end
  end
end
