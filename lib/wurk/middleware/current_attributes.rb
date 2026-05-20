# frozen_string_literal: true

require_relative '../middleware'

module Wurk
  module Middleware
    # Propagates `ActiveSupport::CurrentAttributes` from the enqueueing process
    # into the worker. Off by default — host opts in by calling
    # `Wurk::Middleware::CurrentAttributes.persist(klass_or_array)`.
    #
    # One registered class → job hash key `"cattr"`.
    # Multiple → `"cattr"`, `"cattr_1"`, `"cattr_2"`, … (keys mirror Sidekiq's
    # naming exactly: wire-compat sacred).
    #
    # Spec: docs/target/sidekiq-free.md §10.3 and §2.2.
    module CurrentAttributes
      PERSISTENT_KEY = 'cattr'

      class << self
        # Register one or more CurrentAttributes classes. Re-registering is a
        # no-op: `add` already dedupes by klass, so calling `persist` twice
        # with the same set replaces the old entry with the new args.
        def persist(klass_or_array, config = Wurk.configuration)
          classes = Array(klass_or_array)
          raise ArgumentError, 'persist requires at least one CurrentAttributes class' if classes.empty?

          config.client_middleware.add(Save, classes)
          config.client_middleware.add(Load, classes)
          config.server_middleware.add(Load, classes)
        end

        # Composes the wire key for the Nth registered class. Sidekiq numbers
        # from 1 ("cattr_1"); index 0 keeps the bare "cattr" key.
        def key_for(index)
          index.zero? ? PERSISTENT_KEY : "#{PERSISTENT_KEY}_#{index}"
        end

        # AS::CurrentAttributes#attributes returns a HashWithIndifferentAccess;
        # we coerce to a plain Hash so JSON encoding is predictable.
        def snapshot(klass)
          klass.attributes.to_h
        end

        def restore(klass, attrs)
          attrs&.each { |name, value| klass.public_send("#{name}=", value) }
        end
      end

      # Client-side: snapshot each registered CurrentAttributes class into
      # the job hash. Caller-supplied keys take precedence (`||=`).
      class Save
        include Wurk::Middleware::ClientMiddleware

        def initialize(classes)
          @classes = classes
        end

        def call(_job_class, job, _queue, _redis_pool)
          @classes.each_with_index do |klass, idx|
            key = CurrentAttributes.key_for(idx)
            job[key] ||= CurrentAttributes.snapshot(klass)
          end
          yield
        end
      end

      # Restores each registered CurrentAttributes class for the duration
      # of the inner block, then resets so the next job in the thread
      # starts clean. Reset runs in `ensure` to survive raises and Skip.
      class Load
        include Wurk::Middleware::ServerMiddleware

        def initialize(classes)
          @classes = classes
        end

        def call(_job_or_class, job, _queue)
          @classes.each_with_index do |klass, idx|
            CurrentAttributes.restore(klass, job[CurrentAttributes.key_for(idx)])
          end
          yield
        ensure
          @classes.each(&:reset)
        end
      end
    end
  end
end
