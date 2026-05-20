# frozen_string_literal: true

module Wurk
  module Middleware
    # Server and client chains, same contract as Sidekiq::Middleware::Chain.
    class Chain
      def initialize; end

      def add(klass, *args); end

      def prepend(klass, *args); end

      def remove(klass); end

      # Empty-chain pass-through. Yields the block so callers (Wurk::Client) can
      # rely on `invoke` to return the payload even before the chain has entries.
      def invoke(*_args)
        yield if block_given?
      end
    end
  end
end
