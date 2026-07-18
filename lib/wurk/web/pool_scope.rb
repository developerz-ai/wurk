# frozen_string_literal: true

module Wurk
  class Web
    # Routes `Wurk.redis` onto the dedicated web pool (Wurk::Configuration
    # #web_redis_pool) for the duration of a block.
    #
    # The dashboard, JSON API, and SSE stream run in the host's web process and
    # reach Redis through the same inspector objects (Stats, Queue, Search, …) a
    # worker uses — all of which call `Wurk.redis`. Left on the default pool, a
    # burst of dashboard traffic or a long-held SSE stream could drain the
    # connections a co-located (embedded) worker needs to make progress, and
    # vice versa: the #101 pool-exhaustion incident.
    #
    # `Wurk.redis_pool` resolves its pool by calling `#redis_pool` on
    # `Thread.current[:wurk_capsule]` (falling back to the default capsule).
    # Pointing that thread-local at a handle whose `#redis_pool` is the web pool
    # diverts every nested `Wurk.redis` call with no per-call-site change. The
    # prior value is restored on exit so a reused web-server thread — or a
    # nested scope — is left untouched.
    module PoolScope
      class << self
        def scope
          prev = Thread.current[:wurk_capsule]
          Thread.current[:wurk_capsule] = handle
          yield
        ensure
          Thread.current[:wurk_capsule] = prev
        end

        def handle
          @handle ||= Handle.new
        end
      end

      # Minimal capsule-shaped duck type: Wurk.redis_pool only ever calls
      # `#redis_pool` on the thread-local. Resolved lazily so a post-fork
      # `reset_redis_pools!` rebuild is picked up transparently.
      class Handle
        def redis_pool
          Wurk.configuration.web_redis_pool
        end
      end
    end
  end
end
