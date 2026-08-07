# frozen_string_literal: true

require 'delegate'

module Wurk
  module Test
    # RedisPool decorator that appends every command issued through it — the
    # ones buffered inside a `pipelined`/`multi` block included — to a caller-
    # supplied array, then forwards to the real pool.
    #
    # Sibling of CommandSpy: that one counts commands to bound hot-path traffic,
    # this one keeps the argument vectors so a test can assert *which* commands a
    # boot path sent. The child's eager Lua upload is the motivating case —
    # `SCRIPT LOAD` is server-global and every parallel worker shares one script
    # cache, so `SCRIPT EXISTS` can never tell "this process loaded them" from
    # "a peer test did"; recording what was actually sent is the only
    # non-vacuous assertion.
    #
    # Usage:
    #   sent = []
    #   pool = Wurk::Test::RecordingPool.new(real_pool, sent)
    #   pool.with { |conn| conn.call('PING') }
    #   sent # => [%w[PING]]
    class RecordingPool
      def initialize(pool, sink)
        @pool = pool
        @sink = sink
      end

      def with(idempotent: false, &block)
        @pool.with(idempotent: idempotent) { |conn| block.call(Tap.new(conn, @sink)) }
      end

      def disconnect! = @pool.disconnect!

      # Wraps the connection `with` yields (and, recursively, the buffered
      # pipeline object). Everything but the dispatch methods below forwards
      # untouched via SimpleDelegator.
      class Tap < SimpleDelegator
        BATCH_METHODS = %i[pipelined multi].freeze

        def initialize(conn, sink)
          super(conn)
          @sink = sink
        end

        def call(*args)
          @sink << args
          __getobj__.call(*args)
        end

        def call_v(args)
          @sink << args
          __getobj__.call_v(args)
        end

        BATCH_METHODS.each do |name|
          define_method(name) do |*args, **kwargs, &blk|
            __getobj__.public_send(name, *args, **kwargs) { |batch| blk.call(Tap.new(batch, @sink)) }
          end
        end
      end
    end
  end
end
