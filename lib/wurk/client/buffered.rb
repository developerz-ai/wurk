# frozen_string_literal: true

module Wurk
  class Client
    # Pro feature parity: in-process ring buffer that catches enqueue
    # failures during a Redis outage and replays them on the next push.
    # Activated globally — `Wurk::Client.reliable_push!`. Buffer is
    # per-process, in-memory only; crash = lost. Does NOT cover batch
    # creation or batch-context pushes (`bid` on payload): BATCH_PUSH has
    # atomic counter side-effects we can't safely replay.
    #
    # Spec: docs/target/sidekiq-pro.md §5.
    module Buffered
      DEFAULT_BUFFER_CAP = 1_000
      DRAINING_KEY = :wurk_reliable_push_draining

      # Overflow modes. `:drop_oldest` is the spec default (Sidekiq Pro §5
      # ring buffer). `:raise` lets callers decide what to do on backpressure
      # — Wurk extension surfaced for issue #19's "over-cap pushes raise so
      # callers can decide" requirement.
      OVERFLOW_MODES        = %i[drop_oldest raise].freeze
      DEFAULT_OVERFLOW_MODE = :drop_oldest

      # Raised by `enbuffer` when the cap would be exceeded under
      # `overflow_mode == :raise`. Inherits from RuntimeError so callers
      # can rescue narrowly. The payload that triggered the overflow rides
      # along so the caller can persist/log/forward it.
      class Overflow < RuntimeError
        attr_reader :payload

        def initialize(payload)
          @payload = payload
          super("reliable_push buffer is full (cap=#{Buffered.buffer_cap})")
        end
      end

      # Eagerly initialized: `||=` inside an accessor is not atomic — two
      # threads racing first-touch could end up holding distinct Mutex
      # instances and lose all synchronization on the shared buffer.
      INSTALL_MUTEX = Mutex.new
      BUFFER_MUTEX  = Mutex.new

      class << self
        # Idempotent. Prepends the wrapper module into Wurk::Client so push /
        # push_bulk drain the buffer before each call and raw_push catches
        # connection errors. Safe to call from multiple threads.
        def install!
          install_mutex.synchronize do
            return if @installed

            Wurk::Client.prepend(InstanceMethods)
            @installed = true
          end
        end

        def installed?
          @installed == true
        end

        def buffer_cap
          @buffer_cap ||= DEFAULT_BUFFER_CAP
        end

        def buffer_cap=(value)
          unless value.is_a?(Integer) && value.positive?
            raise ArgumentError, 'reliable_push_buffer must be a positive Integer'
          end

          @buffer_cap = value
        end

        def buffer_size
          buffer_mutex.synchronize { buffer.size }
        end

        def overflow_mode
          @overflow_mode ||= DEFAULT_OVERFLOW_MODE
        end

        def overflow_mode=(mode)
          mode = mode.to_sym
          raise ArgumentError, "overflow_mode must be one of #{OVERFLOW_MODES.inspect}" unless OVERFLOW_MODES.include?(mode)

          @overflow_mode = mode
        end

        def reset!
          buffer_mutex.synchronize do
            @buffer = []
            @buffer_cap = nil
            @overflow_mode = nil
          end
        end

        # Append payloads to the buffer. Behavior on cap exhaustion depends
        # on `overflow_mode`:
        #   * :drop_oldest (default, spec) — ring buffer, oldest evicted.
        #   * :raise                       — Overflow raised, buffer left
        #                                    unchanged for already-appended
        #                                    siblings in the same call; the
        #                                    offending payload is attached
        #                                    to the exception.
        # Drops batched payloads — caller is expected to re-raise for those.
        def enbuffer(payloads)
          cap = buffer_cap
          mode = overflow_mode
          buffer_mutex.synchronize do
            payloads.each do |p|
              if buffer.size >= cap
                raise Overflow, p if mode == :raise

                buffer.shift # :drop_oldest
              end
              buffer << p
            end
          end
        end

        # Drain payloads through `raw_push` on the given client. Stops on
        # the first ConnectionError, preserving order at the head of the
        # buffer so the next push retries the same payload. Emits statsd
        # `jobs.recovered.push` per drained payload.
        def drain!(client)
          drained = 0
          while (payload = pop_head)
            unless attempt_replay(client, payload)
              buffer_mutex.synchronize { buffer.unshift(payload) }
              break
            end

            Wurk::Metrics::Statsd.increment('jobs.recovered.push')
            drained += 1
          end
          drained
        end

        # Internal — visible for tests. Treat as private.
        def buffer
          @buffer ||= []
        end

        # Start a background drain thread that wakes every `interval`
        # seconds and tries to flush the buffer. Idempotent — replaces
        # any prior drainer with one at the new interval. Issue #19
        # requirement: "Background drain thread flushes on reconnect" —
        # handles the case where push activity stops mid-outage so the
        # passive (drain-on-next-push) path never fires.
        def start_drainer!(interval: Drainer::DEFAULT_INTERVAL)
          INSTALL_MUTEX.synchronize do
            @drainer&.stop
            @drainer = Drainer.new(interval: interval)
            @drainer.start
          end
        end

        def stop_drainer!
          INSTALL_MUTEX.synchronize do
            @drainer&.stop
            @drainer = nil
          end
        end

        def drainer_running?
          INSTALL_MUTEX.synchronize { @drainer&.running? == true }
        end

        private

        def install_mutex
          INSTALL_MUTEX
        end

        def buffer_mutex
          BUFFER_MUTEX
        end

        def pop_head
          buffer_mutex.synchronize { buffer.shift }
        end

        # Drain marks the thread so our prepended raw_push re-raises
        # ConnectionError back here instead of swallowing it into the buffer
        # (which would spin forever).
        def attempt_replay(client, payload)
          Thread.current[DRAINING_KEY] = true
          client.send(:raw_push, [payload])
          true
        rescue RedisClient::ConnectionError
          false
        ensure
          Thread.current[DRAINING_KEY] = false
        end
      end

      # Background drain thread. Wakes every `interval` seconds and tries
      # `Buffered.drain!` against a fresh Wurk::Client. drain! already
      # short-circuits on the first ConnectionError, so a still-down Redis
      # just leaves the buffer alone for this tick — no exponential
      # backoff or explicit "reconnect detection" needed; the inner
      # connection retry already lives inside `client.raw_push`.
      class Drainer
        DEFAULT_INTERVAL = 2.0
        STOP_JOIN_TIMEOUT = 5.0

        def initialize(interval: DEFAULT_INTERVAL, client_factory: -> { Wurk::Client.new })
          raise ArgumentError, 'interval must be a positive Numeric' unless interval.is_a?(Numeric) && interval.positive?

          @interval = interval
          @client_factory = client_factory
          @done = false
          @thread = nil
          @wake = ConditionVariable.new
          @lock = Mutex.new
        end

        def start
          @lock.synchronize do
            return if @thread&.alive?

            @done = false
            @thread = Thread.new { run }
            @thread.name = 'wurk-reliable_push-drainer'
          end
        end

        def stop
          @lock.synchronize do
            @done = true
            @wake.broadcast
          end
          @thread&.join(STOP_JOIN_TIMEOUT)
          @thread = nil
        end

        def running?
          @thread&.alive? == true
        end

        private

        def run
          until @done
            wait_interval
            break if @done

            begin
              Buffered.drain!(@client_factory.call)
            rescue StandardError
              # Swallow — next tick retries. Don't let a transient blow up
              # the daemon thread.
            end
          end
        end

        # Mutex+ConditionVariable lets `stop` wake the thread immediately
        # instead of waiting up to `interval` seconds for sleep to return.
        def wait_interval
          @lock.synchronize { @wake.wait(@lock, @interval) unless @done }
        end
      end

      # Wraps Wurk::Client. push / push_bulk drain the buffer first;
      # raw_push catches ConnectionError and buffers non-batched payloads.
      module InstanceMethods
        def push(item)
          Buffered.drain!(self)
          super
        end

        def push_bulk(items)
          Buffered.drain!(self)
          super
        end

        private

        def raw_push(payloads)
          super
        rescue RedisClient::ConnectionError
          raise if Thread.current[Buffered::DRAINING_KEY]

          bidless, batched = payloads.partition { |p| !p['bid'] }
          Buffered.enbuffer(bidless) if bidless.any?
          raise unless batched.empty?
        end
      end
    end

    class << self
      # Activate reliable_push! mode globally. Idempotent — call from the
      # top level of an initializer (NOT inside Wurk.configure_*). Spec:
      # docs/target/sidekiq-pro.md §5.
      def reliable_push! # rubocop:disable Naming/PredicateMethod
        Buffered.install!
        true
      end

      def reliable_push?
        Buffered.installed?
      end

      def reliable_push_buffer
        Buffered.buffer_cap
      end

      def reliable_push_buffer=(value)
        Buffered.buffer_cap = value
      end

      def reliable_push_overflow
        Buffered.overflow_mode
      end

      def reliable_push_overflow=(mode)
        Buffered.overflow_mode = mode
      end

      # Start an opt-in background drainer thread. Implicitly enables
      # reliable_push! so callers don't have to chain the two. Idempotent;
      # calling again replaces the thread with one at the new interval.
      # Spec for reliable_push (sidekiq-pro.md §5) only requires drain on
      # next push — this is a Wurk extension for issue #19's "Background
      # drain thread flushes on reconnect" so producer-stopped-mid-outage
      # buffers don't sit idle until next push.
      def reliable_push_drainer(interval: Buffered::Drainer::DEFAULT_INTERVAL)
        Buffered.install!
        Buffered.start_drainer!(interval: interval)
        true
      end

      def reliable_push_drainer_stop!
        Buffered.stop_drainer!
      end

      def reliable_push_drainer_running?
        Buffered.drainer_running?
      end
    end
  end
end
