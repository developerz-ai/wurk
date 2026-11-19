# frozen_string_literal: true

module Wurk
  # In-memory job store for `:fake` test mode (aliased to Sidekiq::Queues).
  # Wurk::Client#raw_push routes payloads here instead of Redis when
  # `Wurk::Testing.fake?`. Thread-safe so parallel test threads / a job that
  # enqueues more jobs during `drain` don't corrupt the store.
  #
  # Two indexes over the same job hashes, as upstream keeps them: by queue and
  # by class. Both hand out the live Array, so `Sidekiq::Queues["q"]` and
  # `MyJob.jobs` keep counting after the push, which is what RSpec's
  # `change(MyJob.jobs, :size)` reads. Unlike upstream, clearing either one
  # drops the same jobs from the other, so a drain never runs a cleared job.
  #
  # Spec: docs/target/sidekiq-free.md §24.2.
  module Queues
    # An index's Array. Only #clear reaches the other index; other in-place
    # mutators stay local to the list, as upstream's do.
    class List < ::Array
      def initialize(index, key)
        super()
        @index = index
        @key = key
      end

      def clear
        Queues.clear_list(@index, @key)
        self
      end
    end

    ARRAY_CLEAR = ::Array.instance_method(:clear)

    @lock = ::Mutex.new
    @by_queue = ::Hash.new { |h, k| h[k] = List.new(:queue, k) }
    @by_class = ::Hash.new { |h, k| h[k] = List.new(:class, k) }

    class << self
      # Live array reference (not a copy), so the Sidekiq idiom
      # `Sidekiq::Queues["q"].clear` mutates the underlying store like stock.
      def [](queue)
        @lock.synchronize { @by_queue[queue.to_s] }
      end

      def push(queue, klass, job)
        @lock.synchronize do
          @by_queue[queue.to_s] << job
          @by_class[klass.to_s] << job
        end
      end

      # Live hash of queue => [jobs], matching Sidekiq::Queues.jobs_by_queue.
      def jobs_by_queue
        @lock.synchronize { @by_queue }
      end

      # Live hash of class name => [jobs], matching Sidekiq::Queues.jobs_by_class.
      def jobs_by_class
        @lock.synchronize { @by_class }
      end
      alias jobs_by_worker jobs_by_class

      # Every enqueued payload across all queues, flattened.
      def jobs
        @lock.synchronize { @by_queue.values.flatten }
      end

      def delete_for(jid, queue, klass)
        @lock.synchronize do
          @by_queue[queue.to_s].reject! { |j| j['jid'] == jid }
          @by_class[klass.to_s].reject! { |j| j['jid'] == jid }
        end
      end

      def clear_for(queue, klass)
        queue = queue.to_s
        klass = klass.to_s
        @lock.synchronize do
          @by_queue[queue].reject! { |j| j['class'].to_s == klass }
          @by_class[klass].reject! { |j| j['queue'].to_s == queue }
        end
      end

      def clear_all
        @lock.synchronize do
          @by_queue.clear
          @by_class.clear
        end
      end

      # @api private — List#clear: empty one index's list and drop its jobs
      # from the other index.
      def clear_list(index, key)
        @lock.synchronize do
          own, other = index == :queue ? [@by_queue, @by_class] : [@by_class, @by_queue]
          list = own[key]
          drop_all(other, list)
          ARRAY_CLEAR.bind_call(list)
        end
      end

      # --- drain helpers (lock released before the job runs, so a job that
      # enqueues more work doesn't deadlock on the same Mutex) ---------------

      def clear_class(klass)
        jobs_by_class[klass.to_s].clear
      end

      def shift_class(klass)
        @lock.synchronize do
          job = @by_class[klass.to_s].shift
          drop(@by_queue, job) if job
          job
        end
      end

      def shift_any
        @lock.synchronize do
          @by_queue.each_value do |jobs|
            next if jobs.empty?

            job = jobs.shift
            drop(@by_class, job)
            return job
          end
          nil
        end
      end

      private

      # By identity, across every list: `push` is public, so the key a job
      # was filed under need not match its own `queue` / `class` fields.
      def drop(index, job)
        index.each_value { |list| list.delete_if { |j| j.equal?(job) } }
      end

      # #drop for many jobs in one pass over each list, not one per job.
      def drop_all(index, jobs)
        return if jobs.empty?

        gone = ::Set.new.compare_by_identity.merge(jobs)
        index.each_value { |list| list.delete_if { |j| gone.include?(j) } }
      end
    end
  end
end
