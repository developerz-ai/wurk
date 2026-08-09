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
        # Eagerly upload every registered script to the given connection in a
        # single pipelined round-trip (all SCRIPT LOADs, one RTT — not one per
        # script). Idempotent on the Redis side: `SCRIPT LOAD` of the same source
        # returns the same SHA no matter how often it runs. ChildBoot calls this
        # once per child right after the post-fork reconnect so the first real
        # EVALSHA hits a warm cache instead of paying a NOSCRIPT reload. Transient
        # connection errors are the pool wrapper's job (Wurk::RedisPool#with);
        # this only ships the loads.
        def script_load_all(redis)
          redis.pipelined { |pipe| queue_script_loads(pipe) }
        end

        # The same loads, queued onto a pipeline the caller already owns, for a
        # caller with other work to batch with them: ChildBoot pairs them with
        # its liveness PING so a child's whole Redis validation costs one round
        # trip instead of two, on the boot-critical path.
        def queue_script_loads(pipe)
          SCRIPTS.each_value { |src| pipe.call('SCRIPT', 'LOAD', src) }
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

        # Run a pipeline that contains EVALSHAs, recovering from a flushed script
        # cache the way a pipeline forces us to.
        #
        # A pipelined EVALSHA surfaces NOSCRIPT only when the pipeline finalizes
        # — never to #eval_cached's inline rescue, which has already returned by
        # then — and the pipeline applies none of itself when it does. So
        # recovery is one SCRIPT LOAD and a replay of the same block through
        # source-embedded EVAL, which cannot raise NOSCRIPT at all.
        #
        # The block is handed the pipeline and the eval method to route through,
        # and must be replay-safe: it may run twice. Both of Fetcher::Reliable's
        # callers pipeline commands that are (a replayed LREM removes nothing, a
        # replayed reliable_requeue is LREM-guarded, a replayed fetch_slot claims
        # a different job into the same private list).
        def pipelined_eval(redis)
          redis.pipelined { |pipe| yield pipe, :eval_cached }
        rescue RedisClient::CommandError => e
          raise unless noscript?(e)

          script_load_all(redis)
          redis.pipelined { |pipe| yield pipe, :eval_with_source }
        end

        # Source-embedded EVAL — the slow but cache-independent counterpart to
        # `eval_cached`. Used on retry from a pipelined NOSCRIPT recovery where
        # EVALSHA can still race a freshly-loaded script under heavy CI load
        # (cf. WorkerTest NOSCRIPT flake on test (3.4, 7.2)). EVAL ships the
        # full source every call, so it never raises NOSCRIPT.
        def eval_with_source(redis, name, keys:, argv:)
          src = SCRIPTS.fetch(name) { raise ArgumentError, "unknown Lua script: #{name.inspect}" }
          redis.call('EVAL', src, keys.size, *keys, *argv)
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
