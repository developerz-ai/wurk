# frozen_string_literal: true

module Wurk
  # Counters: processed, failed, enqueued, scheduled, retries, dead.
  # Identical Redis keys to Sidekiq.
  class Stats
    def processed; end
    def failed; end
    def enqueued; end
    def scheduled_size; end
    def retry_size; end
    def dead_size; end
  end
end
