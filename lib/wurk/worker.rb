# frozen_string_literal: true

require_relative 'worker/setter'

module Wurk
  # The user-facing job DSL. `include Wurk::Worker` — or its modern alias
  # `Sidekiq::Job` / `Sidekiq::Worker` — onto a class to make it a background
  # job. The class gains `sidekiq_options`, the `perform_*` enqueue methods,
  # `set`, and the retry-hook DSL; each instance gains `jid`, `logger`,
  # `interrupted?`, and the batch helpers.
  #
  # @example A minimal job
  #   class HardJob
  #     include Sidekiq::Job
  #     sidekiq_options queue: "critical", retry: 5
  #
  #     def perform(user_id, opts = {})
  #       # ... your work ...
  #     end
  #   end
  #
  #   HardJob.perform_async(42, "fast" => true)   # enqueue now
  #   HardJob.perform_in(5.minutes, 42)           # enqueue later
  #
  # @see Wurk::Worker::ClassMethods the enqueue + options DSL added to the class
  # @see https://github.com/developerz-ai/wurk/blob/main/docs/migrate-from-sidekiq.md Migration guide
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

    # Class-level DSL mixed into every job class by {Wurk::Worker}. These are
    # the public enqueue and configuration entry points.
    module ClassMethods
      # Set per-class job options (merged over any inherited options).
      #
      # @example
      #   sidekiq_options queue: "mailers", retry: 3, unique_for: 10.minutes
      # @param opts [Hash] any of `queue:`, `retry:`, `dead:`, `backtrace:`,
      #   `expires_in:`, `tags:`, `pool:`, `unique_for:`, … (see the migration
      #   guide's sidekiq_options table for the full set)
      # @return [Hash] the merged, string-keyed options hash
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

      # Enqueue the job to run as soon as a worker is free. Arguments are
      # forwarded to `#perform` and must be JSON-serializable
      # (string/number/bool/nil/array/hash).
      #
      # @example
      #   EmailJob.perform_async(user.id, "welcome")
      # @return [String, nil] the job id (jid), or nil if a client middleware
      #   halted the push
      def perform_async(*)
        Wurk::Worker::Setter.new(self, {}).perform_async(*)
      end

      # Run the job synchronously in the current thread, through both middleware
      # chains (see {Wurk::Worker::Setter#perform_inline}). Useful in tests.
      #
      # @return [true, nil] nil when middleware halted the job, true otherwise
      def perform_inline(*)
        Wurk::Worker::Setter.new(self, {}).perform_inline(*)
      end
      alias perform_sync perform_inline

      # Schedule the job for later. `perform_at` is an alias taking an absolute
      # time; `perform_in` takes a relative interval.
      #
      # @example
      #   ReminderJob.perform_in(1.hour, lead.id)
      #   ReminderJob.perform_at(Time.now + 3600, lead.id)
      # @param interval [Numeric, Time] seconds-from-now, or an absolute Time
      # @return [String, nil] the job id (jid)
      def perform_in(interval, *)
        Wurk::Worker::Setter.new(self, {}).perform_in(interval, *)
      end
      alias perform_at perform_in

      # Enqueue many jobs in one round-trip via the Lua bulk path.
      #
      # @example
      #   ImportJob.perform_bulk([[1], [2], [3]])
      # @param items [Array<Array>] one args array per job
      # @return [Array<String>] the job ids, in order
      def perform_bulk(items, **)
        Wurk::Worker::Setter.new(self, {}).perform_bulk(items, **)
      end

      # Return a per-call option carrier so a single enqueue can override
      # class-level options (queue, scheduling, pool, …).
      #
      # @example
      #   ReportJob.set(queue: "low").perform_async(account.id)
      # @param opts [Hash] per-call overrides
      # @return [Wurk::Worker::Setter]
      def set(opts)
        Wurk::Worker::Setter.new(self, opts)
      end

      def client_push(item)
        raise ArgumentError, "Job arguments to #{name || self} must have string keys" if symbol_keyed?(item)

        # `pool` is a transient enqueue-time attribute: a per-call `set(pool:)`
        # overrides the class-level option, then it's deleted so it never reaches
        # the wire (normalize_item strips any class-level pool re-merged below).
        pool = item.delete('pool') || get_sidekiq_options['pool']
        build_client(pool, client_class: item.delete('client_class')).push(item)
      end

      # `client_class` swaps the enqueue client (e.g. TransactionAwareClient via
      # Wurk.transactional_push!). Resolution order: per-call `set(client_class:)`,
      # then the class option, then the live process default, then Wurk::Client.
      # The default_job_options fallback keeps a global `transactional_push!`
      # order-independent: a class whose options memoized before the opt-in (its
      # inherited copy is a stale dup) still routes through the new client.
      def build_client(pool = get_sidekiq_options['pool'], client_class: nil)
        klass = client_class || get_sidekiq_options['client_class'] ||
                Wurk.default_job_options['client_class'] || Wurk::Client
        klass.new(pool: pool)
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
