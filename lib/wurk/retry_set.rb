# frozen_string_literal: true

require_relative 'job_set'

module Wurk
  # ZSET keyed by next-retry timestamp (score = epoch seconds). Wire-compat
  # with Sidekiq — the `retry` key, score format, and JSON payload all match.
  #
  # Spec: docs/target/sidekiq-free.md §19.5.
  class RetrySet < JobSet
    def initialize
      super('retry')
    end
  end
end
