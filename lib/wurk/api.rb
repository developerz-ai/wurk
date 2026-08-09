# frozen_string_literal: true

module Wurk
  # Namespace for two unrelated things that both answer to "the API": the Pro
  # data-API Lua extensions (API::Fast, required by lib/wurk.rb at its
  # load-order-sensitive point) and the machine-facing HTTP API (API::App).
  module API
    class << self
      # Class-level Rack entry, the same shape as Wurk::Web.call, so
      # `mount Wurk::API => '/wurk-api'` and `run Wurk::API` both work.
      #
      # App and its dependencies (Rack::Request among them) load on the first
      # request rather than at `require "wurk"`. The HTTP API is off unless a
      # host mounts it, and eager-loading it cost every swarm child ~1.2 MB of
      # pre-fork heap and measurably slower boot for a surface it never serves.
      def call(env)
        app.call(env)
      end

      private

      # App is stateless, so every mount — engine-nested, separately mounted,
      # standalone — can share one instance.
      def app
        @app ||= begin
          require_relative 'api/app'
          App.new
        end
      end
    end
  end
end
