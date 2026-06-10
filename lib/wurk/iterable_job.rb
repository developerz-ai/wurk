# frozen_string_literal: true

require 'json'
require_relative 'job'
require_relative 'iterable_job/csv_enumerator'
require_relative 'iterable_job/active_record_enumerator'

module Wurk
  # Iterable jobs split long-running work into small, idempotent chunks.
  # Override `#build_enumerator` (yielding `[item, new_cursor]` pairs) and
  # `#each_iteration(item, *args)`; the framework drives the loop, persists
  # the cursor, and resumes after interruption.
  #
  # Defining `#perform` on the including class is refused at `method_added`
  # — IterableJob owns the run loop. User code overrides `#each_iteration`.
  #
  # State lives in the `it-<jid>` HASH (sidekiq-free.md §1.5):
  #
  #   ex        : execution count (int)
  #   c         : cursor (JSON string)
  #   rt        : runtime accumulated (float seconds)
  #   cancelled : timestamp (int) if cancelled
  #
  # Spec: docs/target/sidekiq-free.md §6.4.
  module IterableJob # rubocop:disable Metrics/ModuleLength
    # Alias to the canonical `Wurk::Job::Interrupted`. The exception lives on
    # `Wurk::Job` so non-iterable code paths (manual `interrupted?` checks)
    # can raise the same class; the interrupt-handler middleware rescues by
    # the `Wurk::Job::Interrupted` name.
    Interrupted = Wurk::Job::Interrupted

    # Default expiry for an iteration state HASH while the job is running or
    # awaiting resume. Refreshed on every checkpoint.
    STATE_TTL = 30 * 86_400

    # Cursor flush + cancellation poll cadence. Both share the timer so
    # a long-running iteration that hits the 5-second mark checkpoints
    # *and* checks for cross-process cancellation in the same tick.
    STATE_FLUSH_INTERVAL = 5

    # Shorter TTL applied once the state is marked cancelled. The HASH
    # outlives `cancel!` long enough for live workers to observe the flag
    # but is reaped well before the 30-day default would expire.
    CANCELLATION_PERIOD = 3 * 86_400

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
    # pairs. The cursor must round-trip through JSON.
    def build_enumerator(*, cursor:)
      _ = cursor
      raise NotImplementedError, "#{self.class} must override #build_enumerator"
    end

    def each_iteration(*)
      raise NotImplementedError, "#{self.class} must override #each_iteration"
    end

    # --- enumerator builders (§6.4) -------------------------------------
    # Helpers user code calls from `#build_enumerator` to get a resumable
    # enumerator of `[item, cursor]` pairs. Cursor parity with Sidekiq:
    # array/CSV use the integer index; ActiveRecord uses the record's
    # primary key.

    def array_enumerator(array, cursor:)
      raise ArgumentError, 'array must be an Array' unless array.is_a?(::Array)

      x = array.each_with_index.drop(cursor || 0)
      x.to_enum { x.size }
    end

    def csv_enumerator(csv, cursor:)
      CsvEnumerator.new(csv).rows(cursor: cursor)
    end

    def csv_batches_enumerator(csv, cursor:, **)
      CsvEnumerator.new(csv).batches(cursor: cursor, **)
    end

    def active_record_records_enumerator(relation, cursor:, **)
      ActiveRecordEnumerator.new(relation, cursor: cursor, **).records
    end

    def active_record_batches_enumerator(relation, cursor:, **)
      ActiveRecordEnumerator.new(relation, cursor: cursor, **).batches
    end

    def active_record_relations_enumerator(relation, cursor:, **)
      ActiveRecordEnumerator.new(relation, cursor: cursor, **).relations
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

    # Mark this iteration cancelled. Sets the in-process flag immediately
    # (so the next `cancelled?` check inside the run loop trips) and, when
    # a jid is bound, writes the timestamp to the `it-<jid>` HASH so other
    # processes observe it on their next 5-second poll.
    #
    # Returns the integer epoch-seconds timestamp written.
    def cancel!
      ts_ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
      @cancelled_at ||= ts_ms
      ts = ts_ms / 1000
      persist_cancellation(ts)
      ts
    end

    # True once `cancel!` has been called locally, OR — for cross-process
    # cancellation — once the `cancelled` field appears in the `it-<jid>`
    # HASH. The remote check is rate-limited to once per `STATE_FLUSH_INTERVAL`
    # to keep the hot loop cheap.
    def cancelled?
      return true if @cancelled_at

      ts = poll_remote_cancellation
      return false unless ts

      @cancelled_at = ts * 1000
      true
    end

    # Redis HASH key holding iteration state for this job. Wire-compat
    # with Sidekiq's `it-<jid>` schema (sidekiq-free.md §1.5).
    def iteration_key
      "it-#{jid}"
    end

    # Foundation run loop. Loads any persisted state, drives the enumerator,
    # checkpoints every `STATE_FLUSH_INTERVAL`, and on interruption persists
    # the final cursor before re-raising so the interrupt-handler middleware
    # can re-push the job at the head of the queue.
    def perform(*args)
      reset_run_state(args)
      load_state
      fire_lifecycle_start
      @executions += 1

      run_iterations(args)

      finalize_complete
    rescue Interrupted
      finalize_interrupted
      raise
    end

    private

    def reset_run_state(args)
      @cancelled_at = nil
      @arguments = args
      @last_cancel_poll_ms = nil
      @last_flush_ms = nil
      @run_started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      @executions = 0
      @runtime_acc = 0.0
      @cursor = nil
    end

    def fire_lifecycle_start
      if @executions.positive?
        on_resume
      else
        on_start
      end
    end

    def run_iterations(args)
      enum = build_enumerator(*args, cursor: @cursor)
      enum.each do |item, new_cursor|
        raise Interrupted if cancelled?

        @current_object = item
        around_iteration { each_iteration(item, *args) }
        @cursor = new_cursor
        maybe_flush_state
      end
    end

    def finalize_complete
      flush_state(final: true)
      on_complete
      delete_state
    end

    def finalize_interrupted
      flush_state(final: true)
      on_cancel if @cancelled_at
      on_stop
    end

    # --- persistence ----------------------------------------------------

    def load_state
      return unless persistable?

      hash = normalize_hgetall(redis_call('HGETALL', iteration_key))
      return if hash.empty?

      apply_loaded_state(hash)
    end

    def apply_loaded_state(hash)
      @executions   = hash['ex'].to_i               if hash['ex']
      @runtime_acc  = hash['rt'].to_f               if hash['rt']
      @cursor       = ::JSON.parse(hash['c'])       if hash['c']
      @cancelled_at = hash['cancelled'].to_i * 1000 if hash['cancelled']
    end

    def maybe_flush_state
      return unless persistable?

      now_ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
      @last_flush_ms ||= now_ms
      return if now_ms - @last_flush_ms < STATE_FLUSH_INTERVAL * 1000

      flush_state
      @last_flush_ms = now_ms
    end

    def flush_state(final: false)
      return unless persistable?

      runtime = @runtime_acc + (::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - @run_started_at)
      @runtime_acc = runtime if final
      ttl = @cancelled_at ? CANCELLATION_PERIOD : STATE_TTL
      redis_pool.with do |conn|
        conn.pipelined do |pipe|
          pipe.call('HSET', iteration_key,
                    'ex', @executions.to_s,
                    'c',  ::JSON.generate(@cursor),
                    'rt', runtime.to_s)
          pipe.call('EXPIRE', iteration_key, ttl)
        end
      end
    end

    def delete_state
      return unless persistable?

      redis_call('DEL', iteration_key)
    end

    def persist_cancellation(timestamp)
      return unless persistable?

      redis_pool.with do |conn|
        conn.pipelined do |pipe|
          pipe.call('HSET', iteration_key, 'cancelled', timestamp)
          pipe.call('EXPIRE', iteration_key, CANCELLATION_PERIOD)
        end
      end
    end

    def poll_remote_cancellation
      return nil unless persistable?

      now_ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
      return nil if @last_cancel_poll_ms && now_ms - @last_cancel_poll_ms < STATE_FLUSH_INTERVAL * 1000

      @last_cancel_poll_ms = now_ms
      raw = redis_call('HGET', iteration_key, 'cancelled')
      raw && !raw.to_s.empty? ? raw.to_i : nil
    end

    # --- helpers --------------------------------------------------------

    def persistable?
      !jid.nil? && !jid.to_s.empty?
    end

    def redis_pool
      Wurk.redis_pool
    end

    def redis_call(*args)
      redis_pool.with { |conn| conn.call(*args) }
    end

    # redis-client returns HGETALL as a flat array on some adapters and as
    # a Hash on others. Normalize to a Hash with String keys/values either way.
    def normalize_hgetall(raw)
      case raw
      when Hash  then raw
      when Array then raw.each_slice(2).to_h
      else            {}
      end
    end
  end

  # Sidekiq drop-in: upstream homes the iterable module (and its enumerator
  # classes) under `Sidekiq::Job::Iterable`. Since `Sidekiq::Job == Wurk::Job`,
  # mirror that so `Sidekiq::Job::Iterable::CsvEnumerator` /
  # `…::ActiveRecordEnumerator` resolve for ported code.
  Job::Iterable = IterableJob unless Job.const_defined?(:Iterable, false)
end
