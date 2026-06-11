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

    module CompatMethods
      def info
        @client.call('INFO') { |i| i.lines(chomp: true).map { |l| l.split(':', 2) }.select { |l| l.size == 2 }.to_h }
      end

      def evalsha(sha, keys, argv)
        @client.call('EVALSHA', sha, keys.size, *keys, *argv)
      end

      # The Redis commands Sidekiq itself uses — defined eagerly so the
      # common ones skip method_missing. Same list as upstream.
      USED_COMMANDS = %w[bitfield bitfield_ro del exists expire flushdb
                         get hdel hget hgetall hincrby hlen hmget hset hsetnx incr incrby
                         lindex llen lmove lpop lpush lrange lrem mget mset ping pttl
                         publish rpop rpush sadd scard script set sismember smembers
                         srem ttl type unlink zadd zcard zincrby zrange zrem
                         zremrangebyrank zremrangebyscore].freeze

      USED_COMMANDS.each do |name|
        define_method(name) do |*args, **kwargs|
          @client.call(name, *args, **kwargs)
        end
      end

      private

      # `conn.hmset(...)` instead of redis-client's native `conn.call("hmset", ...)`.
      def method_missing(*args, &)
        if DEPRECATED_COMMANDS.include?(args.first)
          warn("[sidekiq#5788] Redis has deprecated the `#{args.first}` command, called at #{caller(1..1)}")
        end
        @client.call(*args, &)
      end
      ruby2_keywords :method_missing if respond_to?(:ruby2_keywords, true)

      def respond_to_missing?(_name, _include_private = false)
        super # We can't tell what is a valid command.
      end
    end

    CompatClient = RedisClient::Decorator.create(CompatMethods)

    class CompatClient
      def config
        @client.config
      end
    end
  end
end
