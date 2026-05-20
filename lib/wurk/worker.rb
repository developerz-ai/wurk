# frozen_string_literal: true

require_relative 'worker/setter'

module Wurk
  # The user-facing DSL: `include Wurk::Worker` (aliased to Sidekiq::Worker).
  # Owns `sidekiq_options`, `perform_async`, `perform_in`, `perform_at`,
  # `set`, `sidekiq_retry_in`, etc.
  #
  # Spec: docs/target/sidekiq-free.md §6 (Sidekiq::Job).
  module Worker
    # Interval values below this threshold are interpreted as seconds-from-now;
    # values at or above are treated as absolute epoch timestamps.
    # Threshold matches Sidekiq exactly — wire-compat sacred.
    SCHEDULED_THRESHOLD = 1_000_000_000

    def self.included(base)
      base.extend(ClassMethods)
      base.module_eval { attr_accessor :jid, :_context }
      base.singleton_class.module_eval do
        attr_accessor :sidekiq_retry_in_block, :sidekiq_retries_exhausted_block
      end
    end

    def logger
      Wurk.logger
    end

    # Cooperative cancellation flag for IterableJob and long-running jobs.
    # Returns false when no processor context has been attached.
    def interrupted?
      ctx = @_context
      ctx.respond_to?(:stopping?) && ctx.stopping?
    end

    module ClassMethods
      def sidekiq_options(opts = {})
        merged = get_sidekiq_options.merge(opts.transform_keys(&:to_s))
        @sidekiq_options_hash = merged
      end

      # Sidekiq's public API name — wire-compat sacred. Must stay `get_sidekiq_options`.
      def get_sidekiq_options # rubocop:disable Naming/AccessorMethodName
        @sidekiq_options_hash ||= inherited_sidekiq_options # rubocop:disable Naming/MemoizedInstanceVariableName
      end

      def sidekiq_options_hash
        get_sidekiq_options
      end

      def queue_as(queue)
        sidekiq_options('queue' => queue.to_s)
      end

      def sidekiq_retry_in(&block)
        self.sidekiq_retry_in_block = block
      end

      def sidekiq_retries_exhausted(&block)
        self.sidekiq_retries_exhausted_block = block
      end

      def perform_async(*)
        Wurk::Worker::Setter.new(self, {}).perform_async(*)
      end

      def perform_inline(*)
        new.perform(*)
      end
      alias perform_sync perform_inline

      def perform_in(interval, *)
        Wurk::Worker::Setter.new(self, {}).perform_in(interval, *)
      end
      alias perform_at perform_in

      def perform_bulk(items, **)
        Wurk::Worker::Setter.new(self, {}).perform_bulk(items, **)
      end

      def set(opts)
        Wurk::Worker::Setter.new(self, opts)
      end

      def client_push(item)
        raise ArgumentError, "Job arguments to #{name || self} must have string keys" if symbol_keyed?(item)

        build_client.push(item)
      end

      def build_client
        pool = get_sidekiq_options['pool']
        Wurk::Client.new(pool: pool)
      end

      def delay(*)
        raise ArgumentError, "#{name || self}.delay is removed in Sidekiq 7+. Use #{name || 'klass'}.perform_async."
      end
      alias delay_for delay
      alias delay_until delay

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@sidekiq_options_hash, get_sidekiq_options.dup)
        inherit_block(subclass, :@sidekiq_retry_in_block)
        inherit_block(subclass, :@sidekiq_retries_exhausted_block)
      end

      private

      def inherited_sidekiq_options
        if superclass.respond_to?(:get_sidekiq_options)
          superclass.get_sidekiq_options.dup
        else
          Wurk.default_job_options.dup
        end
      end

      def inherit_block(subclass, ivar)
        return unless instance_variable_defined?(ivar)

        subclass.instance_variable_set(ivar, instance_variable_get(ivar))
      end

      def symbol_keyed?(item)
        item.respond_to?(:keys) && item.keys.any?(Symbol)
      end
    end
  end
end
