# frozen_string_literal: true

module Wurk
  # Capped sorted set of jobs that exhausted retries. Identical to Sidekiq.
  class DeadSet
    def size; end
    def each(&block); end
  end
end
