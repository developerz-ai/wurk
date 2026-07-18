# frozen_string_literal: true

require_relative 'redis_pool'

module Wurk
  # Sidekiq-compatible pool constructor. `Sidekiq::RedisConnection.create(...)`
  # is the documented way to build a standalone Redis pool (spec §26) — it's the
  # default pool for `Sidekiq::Deploy` (§23) and the constructor for per-shard
  # pools in multi-shard web mounts (Pro §10.2). Returns a `Wurk::RedisPool`
  # (connection_pool-backed, redis-client adapter), which is `.with`-compatible
  # with everything that expects a Sidekiq pool.
  #
  # Accepts Sidekiq's option keys (`url`, `size`, `pool_timeout`, `name`) plus
  # the socket knobs (`connect_timeout`/`read_timeout`/`write_timeout`/
  # `reconnect_attempts`/`driver`), string- or symbol-keyed. Anything omitted
  # falls back to RedisPool's defaults (URL = ENV["REDIS_URL"] or
  # redis://localhost:6379/0).
  module RedisConnection
    # Housekeeping/standalone default; per-capsule pools size to concurrency.
    DEFAULT_POOL_SIZE = 10

    def self.create(options = {})
      opts = options.transform_keys(&:to_sym)
      RedisPool.new(size: opts.delete(:size) || DEFAULT_POOL_SIZE, **opts)
    end
  end
end
