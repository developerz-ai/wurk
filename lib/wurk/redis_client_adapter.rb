# frozen_string_literal: true

require 'redis-client'
require 'redis_client/decorator'

module Wurk
  # Command-method compatibility for connections yielded by `Wurk.redis` /
  # `Sidekiq.redis` (#204). Sidekiq 7+ yields RedisClientAdapter::CompatClient,
  # so third-party gems write `conn.hgetall(...)` / `conn.smembers(...)` —
  # method-style commands raw RedisClient doesn't answer (it only has #call).
  # Every pooled connection is wrapped in this decorator at build time
  # (RedisPool#build_client); wurk's own hot paths keep using #call, which the
  # decorator forwards with a single delegation hop.
  #
  # Mirrors sidekiq-8.1.6 lib/sidekiq/redis_client_adapter.rb byte-for-byte in
  # behavior: same fast-path command list, same deprecation warning, same
  # error constants (gems rescue `Sidekiq::RedisClientAdapter::BaseError`).
  class RedisClientAdapter
    BaseError = RedisClient::Error
    CommandError = RedisClient::CommandError

    DEPRECATED_COMMANDS = %i[rpoplpush zrangebyscore zrevrange zrevrangebyscore getset hmset setex setnx].to_set

    # Every method here dispatches through `call` rather than `@client.call` so
    # the round-trip odometer below sees method-style commands too — a host
    # block doing `conn.sadd(...)` then `conn.lpush(...)` has to be as
    # replay-protected as one written with `conn.call`. On the pipeline
    # decorator `call` is the same buffered forward it always was.
    module CompatMethods
      def info
        call('INFO') { |i| i.lines(chomp: true).map { |l| l.split(':', 2) }.select { |l| l.size == 2 }.to_h }
      end

      def evalsha(sha, keys, argv)
        call('EVALSHA', sha, keys.size, *keys, *argv)
      end

      # The Redis commands Sidekiq itself uses — defined eagerly so the
      # common ones skip method_missing. Same list as upstream.
      USED_COMMANDS = %w[bitfield bitfield_ro blmove del exists expire flushdb
                         get hdel hget hgetall hincrby hlen hmget hset hsetnx incr incrby
                         lindex llen lmove lpop lpush lrange lrem mget mset ping pttl
                         publish rpop rpush sadd scard script set sismember smembers
                         srem ttl type unlink zadd zcard zincrby zrange zrem
                         zremrangebyrank zremrangebyscore].freeze

      USED_COMMANDS.each do |name|
        define_method(name) do |*args, **kwargs|
          call(name, *args, **kwargs)
        end
      end

      private

      # `conn.hmset(...)` instead of redis-client's native `conn.call("hmset", ...)`.
      def method_missing(*args, &)
        if DEPRECATED_COMMANDS.include?(args.first)
          warn("[sidekiq#5788] Redis has deprecated the `#{args.first}` command, called at #{caller(1..1)}")
        end
        call(*args, &)
      end
      ruby2_keywords :method_missing if respond_to?(:ruby2_keywords, true)

      def respond_to_missing?(_name, _include_private = false)
        super # We can't tell what is a valid command.
      end
    end

    CompatClient = RedisClient::Decorator.create(CompatMethods)

    class CompatClient
      # Dispatch methods that put commands on the wire and wait for the reply.
      # SCAN and friends are left out on purpose: they are pure reads, so
      # re-running one applies nothing and cannot make a replay unsafe.
      DISPATCH_METHODS = %i[call call_v call_once call_once_v
                            blocking_call blocking_call_v pipelined multi].freeze

      # Round trips this connection has completed, monotonic for its whole life.
      #
      # {Wurk::RedisPool} replays a failed block only while it can prove nothing
      # in it applied, and a connect-phase error proves that for the command
      # that raised — never for the ones before it. redis-client re-dials a
      # dropped socket mid-block, so `CannotConnectError` surfaces on the second
      # pipeline of a block whose first one already landed. The pool snapshots
      # this counter around the block and refuses the replay once it has moved.
      attr_reader :round_trips

      def initialize(client)
        super
        @round_trips = 0
      end

      def config
        @client.config
      end

      # Counted *after* the call returns: a command that never reached a server
      # leaves the odometer where it was, which is what keeps the pre-apply
      # backoff alive for blocks that failed on their very first round trip.
      DISPATCH_METHODS.each do |name|
        class_eval(<<~RUBY, __FILE__, __LINE__ + 1)
          # def call(...)
          #   result = super
          #   @round_trips += 1
          #   result
          # end
          def #{name}(...)
            result = super
            @round_trips += 1
            result
          end
        RUBY
      end
    end
  end
end
