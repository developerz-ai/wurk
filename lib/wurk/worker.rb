# frozen_string_literal: true

module Wurk
  # The user-facing DSL: `include Wurk::Worker` (aliased to Sidekiq::Worker).
  # Owns `sidekiq_options`, `perform_async`, `perform_in`, `perform_at`,
  # `set`, `sidekiq_retry_in`, etc.
  # Spec: docs/target/sidekiq-free.md.
  module Worker
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def sidekiq_options(opts = {}); end
      def perform_async(*args); end
      def perform_in(interval, *args); end
      def perform_at(time, *args); end
      def set(opts); end
    end
  end
end
