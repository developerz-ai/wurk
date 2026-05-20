# frozen_string_literal: true

module Wurk
  # Sorted set keyed by retry-at score. Identical schema to Sidekiq.
  class RetrySet
    def size; end
    def each(&block); end
    def retry_all; end
  end
end
