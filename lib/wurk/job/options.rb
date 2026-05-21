# frozen_string_literal: true

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

      module ClassMethods
        def sidekiq_options(opts = {})
          merged = get_sidekiq_options.merge(opts.transform_keys(&:to_s))
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
