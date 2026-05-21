# frozen_string_literal: true

module Wurk
  module Lua
    # EVALSHA wrapper with `NOSCRIPT` recovery. The SHA1 of each script
    # source is precomputed in `Wurk::Lua::SHAS`, so the first call to
    # `eval_cached` after a fork has a fast path: a single EVALSHA, no
    # per-pool bookkeeping. If the script cache was flushed (manual
    # `SCRIPT FLUSH`, replica failover, OOM eviction), `EVALSHA` returns
    # `NOSCRIPT` — we then `SCRIPT LOAD` once and retry exactly once.
    #
    # Spec: docs/target/sidekiq-free.md §20 (Lua script caching).
    class Loader
      NOSCRIPT_PREFIX = 'NOSCRIPT'

      class << self
        # Eagerly upload every registered script to the given connection.
        # Idempotent on the Redis side: `SCRIPT LOAD` of the same source
        # returns the same SHA regardless of how often it's called.
        # Manager calls this once per child after the post-fork reconnect.
        def script_load_all(redis)
          SCRIPTS.each_value { |src| redis.call('SCRIPT', 'LOAD', src) }
        end

        # @param redis [RedisClient] a single connection (not a pool)
        # @param name [Symbol] key into Wurk::Lua::SCRIPTS
        # @param keys [Array<String>] EVALSHA KEYS
        # @param argv [Array] EVALSHA ARGV (coerced to strings by Redis)
        # @return Lua script return value
        def eval_cached(redis, name, keys:, argv:)
          src = SCRIPTS.fetch(name) { raise ArgumentError, "unknown Lua script: #{name.inspect}" }
          sha = SHAS.fetch(name)
          evalsha(redis, sha, keys, argv)
        rescue RedisClient::CommandError => e
          raise unless noscript?(e)

          redis.call('SCRIPT', 'LOAD', src)
          evalsha(redis, sha, keys, argv)
        end

        private

        def evalsha(redis, sha, keys, argv)
          redis.call('EVALSHA', sha, keys.size, *keys, *argv)
        end

        def noscript?(err)
          err.message.to_s.start_with?(NOSCRIPT_PREFIX)
        end
      end
    end
  end
end
