# frozen_string_literal: true

module Wurk
  module Middleware
    # Server and client chains, same contract as Sidekiq::Middleware::Chain.
    class Chain
      def initialize; end

      def add(klass, *args); end

      def prepend(klass, *args); end

      def remove(klass); end

      def invoke(*args, &block); end
    end
  end
end
