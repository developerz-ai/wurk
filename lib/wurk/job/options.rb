# frozen_string_literal: true

require_relative '../collapse'
require_relative '../job_util'

module Wurk
  module Job
    # Options-only slice of the Wurk::Worker DSL. Mixed into `ActiveJob::Base`
    # by the wurk adapter so native AJ classes can configure Wurk/Sidekiq
    # features (`sidekiq_options retry: 3`, `sidekiq_retry_in { ... }`, …)
    # without including the full `perform_async`/`set` surface that doesn't
    # apply to AJ.
    #
    # Aliased as `Sidekiq::Job::Options`. Wire-compat sacred — third-party
    # gems that extend AJ via this module load unchanged.
    #
    # Spec: docs/target/sidekiq-free.md §6 (Sidekiq::Job::Options).
    module Options
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Also the options half of {Wurk::Worker::ClassMethods}, so an ActiveJob
      # class configuring a Wurk option is told about a bad value at the same
      # place a plain worker is.
      module ClassMethods
        # Set per-class job options (merged over any inherited options).
        #
        # @example
        #   sidekiq_options queue: "mailers", retry: 3, unique_for: 10.minutes
        # @example Opt into Wurk::Status tracking
        #   sidekiq_options track: true
        # @example Bound one attempt, and the job as a whole
        #   sidekiq_options timeout: 30, deadline: 5.minutes
        # @example Collapse a burst of enqueues into one job
        #   sidekiq_options collapse: { policy: :debounce, wait: 5, max_wait: 60 }
        # @param opts [Hash] any of `queue:`, `retry:`, `dead:`, `backtrace:`,
        #   `expires_in:`, `tags:`, `pool:`, `unique_for:`, `track:`, `timeout:`,
        #   `deadline:`, `collapse:`, … (see the migration guide's sidekiq_options
        #   table for the full set)
        # @return [Hash] the merged, string-keyed options hash
        def sidekiq_options(opts = {})
          stringified = opts.transform_keys(&:to_s)
          Wurk::JobUtil.validate_track!(stringified['track'], stringified) if stringified.key?('track')
          Wurk::JobUtil.validate_bounds!(stringified)
          merged = get_sidekiq_options.merge(stringified)
          # On the merged options rather than the new ones, and before the
          # assign: a subclass adding `collapse:` to a parent's `unique_for:`
          # has declared both, and only the merge can see it. Raising first
          # leaves the class holding the options it had.
          Wurk::Collapse.policy_for(merged)
          @sidekiq_options_hash = merged
        end

        # Sidekiq's public API name — must stay `get_sidekiq_options`.
        def get_sidekiq_options # rubocop:disable Naming/AccessorMethodName
          @sidekiq_options_hash ||= inherited_sidekiq_options # rubocop:disable Naming/MemoizedInstanceVariableName
        end

        def sidekiq_options_hash
          get_sidekiq_options
        end

        attr_reader :sidekiq_retry_in_block, :sidekiq_retries_exhausted_block

        def sidekiq_retry_in(&block)
          @sidekiq_retry_in_block = block
        end

        def sidekiq_retries_exhausted(&block)
          @sidekiq_retries_exhausted_block = block
        end

        def inherited(subclass)
          super
          subclass.instance_variable_set(:@sidekiq_options_hash, get_sidekiq_options.dup)
          inherit_ivar(subclass, :@sidekiq_retry_in_block)
          inherit_ivar(subclass, :@sidekiq_retries_exhausted_block)
        end

        private

        def inherited_sidekiq_options
          if superclass.respond_to?(:get_sidekiq_options)
            superclass.get_sidekiq_options.dup
          else
            Wurk.default_job_options.dup
          end
        end

        def inherit_ivar(subclass, ivar)
          return unless instance_variable_defined?(ivar)

          subclass.instance_variable_set(ivar, instance_variable_get(ivar))
        end
      end
    end
  end
end
