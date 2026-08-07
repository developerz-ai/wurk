# frozen_string_literal: true

require_relative 'redis_pool'

module Wurk
  # The seam every `#redis`-style wrapper checks out through.
  #
  # `idempotent:` is a {Wurk::RedisPool} concept — it re-enables block replay
  # after a command may already have applied server-side (see RedisPool#with).
  # The object behind a wrapper is not always ours, though: the Sidekiq surface
  # Wurk drops into lets a host supply any ConnectionPool-shaped object
  # (`Sidekiq::Client#redis_pool=`, `Sidekiq::Web.redis_pool=`, the `pool:`
  # kwarg on Stats::History / Deploy / Leader / Profiler / Metrics::History),
  # and a bare `def with; yield conn; end` decorator — the shape people reach
  # for to count or trace round trips — is a legal implementation of it. Handing
  # that an unknown keyword is an ArgumentError, so the claim goes only to a pool
  # that understands it.
  #
  # Dropping the claim is always sound: the pool falls back to the conservative
  # no-replay default, which is exactly what a foreign pool did before the
  # keyword existed. Apply-safety is an optimization, never a correctness input.
  module PoolCheckout
    def self.with(pool, idempotent, &)
      return pool.with(&) unless idempotent && pool.is_a?(RedisPool)

      pool.with(idempotent: true, &)
    end

    # Same apply-safety forwarding as .with, minus the is_a? probe. Only for
    # call sites whose pool is always this process's own {RedisPool} — never a
    # host-supplied `pool:` kwarg — so the polymorphic check has nothing to
    # decide.
    def self.trusted(pool, idempotent, &)
      return pool.with(&) unless idempotent

      pool.with(idempotent: true, &)
    end
  end
end
