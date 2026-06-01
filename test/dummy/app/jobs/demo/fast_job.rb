# frozen_string_literal: true

module Demo
  # The bulk of demo throughput: tiny work that almost always succeeds, spread
  # across queues so the Queues widget and the throughput chart show signal.
  class FastJob
    include Wurk::Job

    def perform(*)
      sleep(rand * 0.02)
    end
  end
end
