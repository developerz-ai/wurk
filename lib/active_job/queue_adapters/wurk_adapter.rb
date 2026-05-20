# frozen_string_literal: true

# ActiveJob adapter. Rails resolves `:wurk` to this class via the
# QueueAdapters lookup convention. The body delegates to Wurk::Client.
# Spec: docs/target/sidekiq-free.md (ActiveJob integration).

module ActiveJob
  module QueueAdapters
    class WurkAdapter
      def enqueue(job)
        # TODO: Wurk::Client.new.push(serialized_payload_for(job))
      end

      def enqueue_at(job, timestamp)
        # TODO: schedule via Wurk::ScheduledSet
      end
    end
  end
end
