# frozen_string_literal: true

module Wurk
  # Sidekiq-compatible middleware contract. Both client and server middleware
  # share the same surface (Sidekiq aliases `ClientMiddleware = ServerMiddleware`).
  # Including this gives a middleware class a `config` setter (the Chain assigns
  # it via `Entry#make_new`) plus convenience accessors to the bound config's
  # Redis pool and logger.
  #
  # `config` is either a Wurk::Configuration or a Wurk::Capsule — both expose
  # `redis_pool`, `redis`, `logger`. Treat config as the single seam between
  # middleware and the host process.
  #
  # Spec: docs/target/sidekiq-free.md §10.2.
  module Middleware
    module ServerMiddleware
      attr_accessor :config

      def redis_pool
        config.redis_pool
      end

      def logger
        config.logger
      end

      def redis(&)
        config.redis(&)
      end
    end

    ClientMiddleware = ServerMiddleware
  end
end
