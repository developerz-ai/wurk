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

    # Module-level test helpers: `Sidekiq::Worker.jobs / clear_all / drain_all`
    # operate across every job class (spec §24.3). Resolved lazily so the
    # testing constants need not be loaded when Worker is.
    def self.jobs       = ::Wurk::Queues.jobs
    def self.clear_all  = ::Wurk::Queues.clear_all
    def self.drain_all  = ::Wurk::Testing.drain_all

    def logger
      Wurk.logger
    end

    # Cooperative cancellation flag for IterableJob and long-running jobs.
    # Returns false when no processor context has been attached.
    def interrupted?
      ctx = @_context
      ctx.respond_to?(:stopping?) && ctx.stopping?
    end

    # Batch helpers (Pro). Available on every worker — return nil when the
    # current job did not originate from a batch.
    #
    # Spec: docs/target/sidekiq-pro.md §2.6.
    def bid
      @bid
    end

    # @api private — Processor sets this from job_hash['bid'] before perform.
    attr_writer :bid

    def batch
      return nil if @bid.nil?

      Wurk::Batch.new(@bid)
    end

    # False if the batch was invalidated. Workers should `return unless
    # valid_within_batch?` to short-circuit work for cancelled batches.
    def valid_within_batch?
      return true if @bid.nil?

      batch.valid?
    end

    module ClassMethods # rubocop:disable Metrics/ModuleLength
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

        # `pool` is a transient enqueue-time attribute: a per-call `set(pool:)`
        # overrides the class-level option, then it's deleted so it never reaches
        # the wire (normalize_item strips any class-level pool re-merged below).
        pool = item.delete('pool') || get_sidekiq_options['pool']
        build_client(pool).push(item)
      end

      def build_client(pool = get_sidekiq_options['pool'])
        Wurk::Client.new(pool: pool)
      end

      # --- Sidekiq::Testing class-level helpers (spec §24.3) --------------
      # Only meaningful in :fake / :inline mode; the in-memory store is empty
      # otherwise.

      def queue
        get_sidekiq_options['queue']
      end

      # Fake jobs enqueued for this class, across every queue.
      def jobs
        ::Wurk::Queues.jobs_by_class[to_s] || []
      end

      def clear
        ::Wurk::Queues.clear_class(to_s)
      end

      # Run & remove every fake job for this class — including ones it enqueues
      # mid-drain. Returns the count processed.
      def drain
        count = 0
        while (job = ::Wurk::Queues.shift_class(to_s))
          process_job(job)
          count += 1
        end
        count
      end

      # Run & remove the first fake job for this class; EmptyQueueError if none.
      def perform_one
        job = ::Wurk::Queues.shift_class(to_s)
        raise ::Wurk::Testing::EmptyQueueError, "no #{self} jobs were found" if job.nil?

        process_job(job)
      end

      # Execute a normalized job hash through the inline server-middleware chain
      # (empty by default — see Wurk::Testing.server_middleware).
      # Returns the value of the server-middleware `invoke` (i.e. the worker's
      # `perform` return), matching Sidekiq::Testing — so `perform_one` yields
      # the job result.
      def process_job(job_hash)
        instance = new
        instance.jid = job_hash['jid']
        instance.bid = job_hash['bid'] if instance.respond_to?(:bid=)
        ::Wurk::Testing.server_middleware.invoke(instance, job_hash, job_hash['queue'] || queue) do
          execute_job(instance, job_hash['args'])
        end
      end

      def execute_job(worker, args)
        worker.perform(*args)
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
