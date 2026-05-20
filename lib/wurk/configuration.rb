# frozen_string_literal: true

module Wurk
  # Owns runtime knobs (workers, concurrency, queues, shutdown_timeout,
  # memory_limit, swarm topology) and the per-process Redis pool.
  # Spec: docs/target/sidekiq-free.md (configure_server / configure_client).
  class Configuration
    def initialize
      # TODO: populate defaults — see docs/idea/03-process-model.md
    end

    def configure_server(&block); end

    def configure_client(&block); end

    def redis_pool
      # TODO: lazy build of Wurk::RedisPool, per-fork.
    end

    def logger
      # TODO
    end
  end
end
