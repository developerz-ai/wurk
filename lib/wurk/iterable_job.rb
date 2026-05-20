# frozen_string_literal: true

require_relative 'job'

module Wurk
  # Iterable jobs split long-running work into small, idempotent chunks.
  # Override `#build_enumerator` (yielding `[item, new_cursor]` pairs) and
  # `#each_iteration(item, *args)`; the framework drives the loop, persists
  # the cursor, and resumes after interruption.
  #
  # Defining `#perform` on the including class is refused at `method_added`
  # — IterableJob owns the run loop. User code overrides `#each_iteration`.
  #
  # **PR 2 ships the contract only.** Cursor persistence to the `it-<jid>`
  # HASH, the 5-second checkpoint cadence, and cross-process cancellation
  # all land in PR 8. The in-process `#cancel!` here is cooperative within
  # a single run.
  #
  # Spec: docs/target/sidekiq-free.md §6.4.
  module IterableJob
    # Alias to the canonical `Wurk::Job::Interrupted`. The exception lives on
    # `Wurk::Job` so non-iterable code paths (manual `interrupted?` checks)
    # can raise the same class; the interrupt-handler middleware rescues by
    # the `Wurk::Job::Interrupted` name.
    Interrupted = Wurk::Job::Interrupted

    # Class-level guard injected via singleton-class prepend so we can call
    # `super` cleanly and stay compatible with anything else hooking
    # `method_added`.
    module MethodAddedGuard
      def method_added(method_name)
        if method_name == :perform
          raise ArgumentError,
                "#{self} is an IterableJob; override #each_iteration instead of #perform"
        end
        super
      end
    end

    def self.included(base)
      base.include(Wurk::Job)
      base.singleton_class.prepend(MethodAddedGuard)
    end

    # User overrides — must return an Enumerator yielding `[item, new_cursor]`
    # pairs. The cursor must round-trip through JSON (PR 8 persists it).
    def build_enumerator(*, cursor:)
      _ = cursor
      raise NotImplementedError, "#{self.class} must override #build_enumerator"
    end

    def each_iteration(*)
      raise NotImplementedError, "#{self.class} must override #each_iteration"
    end

    # --- lifecycle hooks (no-op defaults; users override as needed) -----

    def on_start; end
    def on_resume; end
    def on_stop; end
    def on_cancel; end
    def on_complete; end

    def around_iteration
      yield
    end

    # --- iteration state accessors --------------------------------------

    attr_reader :current_object

    def arguments
      @arguments ||= []
    end

    def cursor
      @cursor
    end

    # Cooperative in-process cancellation. PR 8 promotes this to a HASH
    # write so other processes (and the dashboard) can flip the flag.
    def cancel!
      # Store first-cancellation timestamp; subsequent calls are no-ops.
      @cancelled_at ||= ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond) # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    def cancelled?
      !@cancelled_at.nil?
    end

    # Redis HASH key holding iteration state for this job. Wire-compat
    # with Sidekiq's `it-<jid>` schema (sidekiq-free.md §1.5).
    def iteration_key
      "it-#{jid}"
    end

    # Foundation run loop. No cursor persistence, no resume — those land in
    # PR 8 along with the `STATE_FLUSH_INTERVAL` checkpoint and morgue
    # handling. Kept here so user worker classes are runnable end-to-end
    # under `perform_inline` and the parity tests.
    def perform(*args)
      @cancelled_at = nil
      @arguments = args
      on_start
      enum = build_enumerator(*args, cursor: @cursor)
      enum.each do |item, new_cursor|
        raise Interrupted if cancelled?

        @current_object = item
        around_iteration { each_iteration(item, *args) }
        @cursor = new_cursor
      end
      on_complete
    end
  end
end
