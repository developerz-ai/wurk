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

        def reset!
          buffer_mutex.synchronize do
            @buffer = []
            @buffer_cap = nil
          end
        end

        # Append payloads to the ring; oldest evicted when over cap.
        # Drops batched payloads — caller is expected to re-raise for those.
        def enbuffer(payloads)
          cap = buffer_cap
          buffer_mutex.synchronize do
            payloads.each do |p|
              buffer << p
              buffer.shift while buffer.size > cap
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

        private

        def install_mutex
          @install_mutex ||= Mutex.new
        end

        def buffer_mutex
          @buffer_mutex ||= Mutex.new
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
    end
  end
end
