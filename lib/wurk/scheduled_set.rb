# frozen_string_literal: true

module Wurk
  # Sorted set for jobs scheduled at a future time. Identical to Sidekiq.
  class ScheduledSet
    def size; end
    def each(&block); end
  end
end
