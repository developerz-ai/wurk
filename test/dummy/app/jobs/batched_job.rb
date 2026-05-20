# frozen_string_literal: true

# Uses Wurk::Batch (aliased to Sidekiq::Batch). Pro parity.
class BatchedJob
  include Wurk::Worker

  def perform(*args); end
end
