# frozen_string_literal: true

# Plain ActiveJob via the Wurk adapter — exercises the most common path.
class SimpleJob < ActiveJob::Base
  queue_as :default

  def perform(*args)
    # TODO: write a sentinel to Redis the integration test can poll for.
  end
end
