# frozen_string_literal: true

module Demo
  # A member of a demo batch. Mostly succeeds; a small slice dies (retry: 0) so
  # the batch's failure count and the :death callback get exercised too.
  class BatchChildJob
    include Wurk::Job

    sidekiq_options retry: 0

    def perform(*)
      sleep(rand * 0.01)
      raise 'batch child failed' if rand < 0.1
    end
  end
end
