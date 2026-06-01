# frozen_string_literal: true

module Wurk
  # In-memory job store for `:fake` test mode (aliased to Sidekiq::Queues).
  # Wurk::Client#raw_push routes payloads here instead of Redis when
  # `Wurk::Testing.fake?`. Thread-safe so parallel test threads / a job that
  # enqueues more jobs during `drain` don't corrupt the store.
  #
  # Spec: docs/target/sidekiq-free.md §24.2.
  module Queues
    @lock = ::Mutex.new
    @by_queue = ::Hash.new { |h, k| h[k] = [] }

    class << self
      def [](queue)
        @lock.synchronize { @by_queue[queue.to_s].dup }
      end

      def push(queue, _klass, job)
        @lock.synchronize { @by_queue[queue.to_s] << job }
      end

      def jobs_by_queue
        @lock.synchronize { @by_queue.transform_values(&:dup) }
      end

      def jobs_by_class
        @lock.synchronize { @by_queue.values.flatten.group_by { |j| j['class'].to_s } }
      end
      alias jobs_by_worker jobs_by_class

      # Every enqueued payload across all queues, flattened.
      def jobs
        @lock.synchronize { @by_queue.values.flatten }
      end

      def delete_for(jid, queue, _klass)
        @lock.synchronize { @by_queue[queue.to_s].reject! { |j| j['jid'] == jid } }
      end

      def clear_for(queue, klass)
        klass = klass.to_s
        @lock.synchronize { @by_queue[queue.to_s].reject! { |j| j['class'].to_s == klass } }
      end

      def clear_all
        @lock.synchronize { @by_queue.clear }
      end

      # --- drain helpers (lock released before the job runs, so a job that
      # enqueues more work doesn't deadlock on the same Mutex) ---------------

      def clear_class(klass)
        klass = klass.to_s
        @lock.synchronize { @by_queue.each_value { |jobs| jobs.reject! { |j| j['class'].to_s == klass } } }
      end

      def shift_class(klass)
        klass = klass.to_s
        @lock.synchronize do
          @by_queue.each_value do |jobs|
            idx = jobs.index { |j| j['class'].to_s == klass }
            return jobs.delete_at(idx) if idx
          end
          nil
        end
      end

      def shift_any
        @lock.synchronize do
          @by_queue.each_value { |jobs| return jobs.shift unless jobs.empty? }
          nil
        end
      end
    end
  end
end
