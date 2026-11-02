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
    # Classes are kept by name and resolved per job, as a String registered from
    # an initializer has to be. It also means a class object passed here doesn't
    # go stale once development code reloading replaces the constant.
    #
    # Spec: docs/target/sidekiq-free.md §10.3 and §2.2.
    module CurrentAttributes
      PERSISTENT_KEY = 'cattr'

      class << self
        # Register one or more CurrentAttributes classes. Re-registering is a
        # no-op: `add` already dedupes by klass, so calling `persist` twice
        # with the same set replaces the old entry with the new args.
        def persist(klass_or_array, config = Wurk.configuration)
          classes = Array(klass_or_array).map { |klass| reference_for(klass) }
          raise ArgumentError, 'persist requires at least one CurrentAttributes class' if classes.empty?

          config.client_middleware.add(Save, classes)
          config.client_middleware.add(Load, classes)
          # Outermost, so every other server middleware sees the job's attributes.
          config.server_middleware.prepend(Load, classes)
        end

        # An anonymous class has no name to look up again, so it stays as given.
        def reference_for(klass)
          klass.is_a?(Module) ? klass.name || klass : klass.to_s
        end

        def resolve(reference)
          reference.is_a?(String) ? Object.const_get(reference) : reference
        end

        # Composes the wire key for the Nth registered class. Sidekiq numbers
        # from 1 ("cattr_1"); index 0 keeps the bare "cattr" key.
        def key_for(index)
          index.zero? ? PERSISTENT_KEY : "#{PERSISTENT_KEY}_#{index}"
        end

        # AS::CurrentAttributes#attributes returns a HashWithIndifferentAccess;
        # we coerce to a plain Hash so JSON encoding is predictable. `.dup` so
        # the snapshot is a detached copy — Load holds onto the pre-job state
        # and must not see it mutated when it restores the job's attributes,
        # and Save must not alias live attributes into the persisted job hash.
        def snapshot(klass)
          klass.attributes.to_h.dup
        end

        def restore(klass, attrs)
          attrs&.each { |name, value| klass.public_send("#{name}=", value) }
        end
      end

      # Client-side: snapshot each registered CurrentAttributes class into
      # the job hash. Caller-supplied keys take precedence (`||=`), and a class
      # with nothing set adds no key, so the payload doesn't grow an empty one.
      class Save
        include Wurk::Middleware::ClientMiddleware

        def initialize(classes)
          @classes = classes
        end

        def call(_job_class, job, _queue, _redis_pool)
          @classes.each_with_index do |reference, idx|
            attrs = CurrentAttributes.snapshot(CurrentAttributes.resolve(reference))
            job[CurrentAttributes.key_for(idx)] ||= attrs unless attrs.empty?
          end
          yield
        end
      end

      # Restores each registered CurrentAttributes class for the duration
      # of the inner block, then puts back whatever was there before — not a
      # blanket reset. On a server thread the prior state is empty, so this is
      # equivalent to resetting; but Load also runs on the CLIENT chain (persist
      # registers it on both), where an enqueue happens mid-request with
      # request-scoped attributes already set. Resetting there would wipe the
      # caller's state right after `perform_async`. Save/restore is what Sidekiq
      # does and is correct on both chains. Restore runs in `ensure` to survive
      # raises and Skip.
      #
      # Registered on BOTH chains, so `call` takes an optional 4th arg: the
      # client chain passes a `redis_pool`, the server chain stops at `queue`.
      class Load
        include Wurk::Middleware::ServerMiddleware

        def initialize(classes)
          @classes = classes
        end

        def call(_job_or_class, job, _queue, _redis_pool = nil)
          classes = @classes.map { |reference| CurrentAttributes.resolve(reference) }
          previous = classes.map { |klass| CurrentAttributes.snapshot(klass) }
          classes.each_with_index do |klass, idx|
            CurrentAttributes.restore(klass, job[CurrentAttributes.key_for(idx)])
          end
          yield
        ensure
          previous&.each_with_index do |attrs, idx|
            classes[idx].reset
            CurrentAttributes.restore(classes[idx], attrs)
          end
        end
      end
    end
  end
end

# Drop-in alias. Sidekiq documents the top-level constant
# `Sidekiq::CurrentAttributes` (with `.persist` and `Save`/`Load` nested),
# not the `Middleware::`-namespaced form. Set when this opt-in file is
# required, so `Sidekiq::CurrentAttributes.persist(MyAttrs)` resolves.
Sidekiq::CurrentAttributes = Wurk::Middleware::CurrentAttributes if defined?(Sidekiq)
