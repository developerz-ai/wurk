# frozen_string_literal: true

require 'delegate'

module Wurk
  module Test
    # Command-counting `Thread.current[:wurk_capsule]` install, for tests that
    # must bound Redis traffic. Lifted from the `RoundTripCounter` pattern in
    # test/unit/web_search_test.rb (thread-local override, not a global
    # monkeypatch, so counting stays safe under `parallelize_me!`) but counts a
    # different thing: RedisClientAdapter::CompatClient#round_trips
    # (redis_client_adapter.rb:75-76) counts one per `pipelined`/`multi` call no
    # matter how many commands it buffers, so a change that fans one command out
    # into a ten-command pipeline would read as flat there. This counts actual
    # commands, walking into `pipelined`/`multi` blocks to tally what they buffer.
    #
    # Usage:
    #   spy = Wurk::Test::CommandSpy.new(Wurk.redis_pool)
    #   Thread.current[:wurk_capsule] = spy
    #   # ... exercise code under test ...
    #   spy.count
    #   Thread.current[:wurk_capsule] = nil
    class CommandSpy
      attr_reader :count

      # `pipelined`/`multi` are the only DISPATCH_METHODS that can hide more than
      # one command behind a single round trip; every other dispatch (call,
      # call_v, blocking_call, ...) plus every convenience method (smembers,
      # hgetall, ...) already resolves to exactly one round trip on the real
      # connection, so `round_trips` alone counts those correctly.
      BATCH_METHODS = %i[pipelined multi].freeze

      def initialize(pool)
        @pool = pool
        @count = 0
      end

      # Doubles as its own `Thread.current[:wurk_capsule]` binding (`#redis_pool`
      # returns self), same as RoundTripCounter.
      def redis_pool = self

      def with(&block)
        @pool.with do |conn|
          before = conn.round_trips
          result = block.call(Tap.new(conn, self))
          @count += conn.round_trips - before
          result
        end
      end

      # Called once a `pipelined`/`multi` block returns, with how many commands
      # it actually buffered. The block's own round trip already added 1 to
      # `@count` via the `round_trips` delta in `#with`, so this corrects that
      # single count to the real number (including 0, for an empty block that
      # still spends a round trip on nothing).
      def record_batch(actual_commands)
        @count += actual_commands - 1
      end

      # Wraps the connection `with` yields. Only `pipelined`/`multi` need
      # overriding — every other method (`call`, `call_v`, convenience commands
      # like `smembers`) is left to resolve on the real connection via
      # SimpleDelegator forwarding, so it still increments the real
      # `round_trips` counter that `#with` reads.
      class Tap < SimpleDelegator
        def initialize(conn, spy)
          super(conn)
          @spy = spy
        end

        CommandSpy::BATCH_METHODS.each do |name|
          define_method(name) do |*args, **kwargs, &blk|
            counter = Counter.new
            result = __getobj__.public_send(name, *args, **kwargs) { |batch| blk.call(Batch.new(batch, counter)) }
            @spy.record_batch(counter.count)
            result
          end
        end
      end

      # Plain counter shared between a `Tap#pipelined`/`#multi` call and the
      # `Batch` it yields.
      class Counter
        attr_accessor :count

        def initialize
          @count = 0
        end
      end

      # Wraps the buffered pipeline/transaction object redis-client yields to a
      # `pipelined`/`multi` block; each `call`-family invocation on it queues one
      # command, so each one increments the shared counter.
      class Batch < SimpleDelegator
        DISPATCH_METHODS = %i[call call_v call_once call_once_v].freeze

        def initialize(batch, counter)
          super(batch)
          @counter = counter
        end

        DISPATCH_METHODS.each do |name|
          define_method(name) do |*args, **kwargs, &blk|
            @counter.count += 1
            __getobj__.public_send(name, *args, **kwargs, &blk)
          end
        end
      end
    end
  end
end
