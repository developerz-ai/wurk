# frozen_string_literal: true

require 'delegate'

module Wurk
  module Test
    # Records each command `Wurk.redis` sends on this thread together with the
    # batch it rode in: `:multi`, `:pipelined`, or nil for a bare call. Lets a
    # test pin "these writes go in one MULTI" — the one property a real Redis
    # can't show afterwards, since a pipeline leaves the same end state.
    # Thread-local (`Thread.current[:wurk_capsule]`), like CommandSpy, so it's
    # safe under `parallelize_me!`.
    #
    #   log = Wurk::Test::BatchSpy.record { queue.clear }
    #   log # => [[:multi, ['UNLINK', 'queue:x']], [:multi, ['SREM', 'queues', 'x']]]
    class BatchSpy
      def self.record(pool = Wurk.redis_pool)
        spy = new(pool)
        previous = Thread.current[:wurk_capsule]
        Thread.current[:wurk_capsule] = spy
        yield
        spy.log
      ensure
        Thread.current[:wurk_capsule] = previous
      end

      attr_reader :log

      def initialize(pool)
        @pool = pool
        @log = []
      end

      def redis_pool = self

      def with(&block)
        @pool.with { |conn| block.call(Tap.new(conn, @log, nil)) }
      end

      # Wraps the connection, and recursively the batch object a
      # `multi`/`pipelined` block receives, tagging each command with its batch.
      class Tap < SimpleDelegator
        def initialize(conn, log, batch)
          super(conn)
          @log = log
          @batch = batch
        end

        def call(*args, **)
          @log << [@batch, args]
          __getobj__.call(*args, **)
        end

        %i[multi pipelined].each do |name|
          define_method(name) do |*args, **kwargs, &blk|
            __getobj__.public_send(name, *args, **kwargs) { |batch| blk.call(Tap.new(batch, @log, name)) }
          end
        end
      end
    end
  end
end
