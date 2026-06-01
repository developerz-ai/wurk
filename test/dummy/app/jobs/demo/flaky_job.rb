# frozen_string_literal: true

module Demo
  # Fails about half the time, then recovers on a short backoff — keeps the
  # Retries widget and the failure-rate chart populated without jobs lingering
  # for the default exponential backoff (which would take minutes to show).
  class FlakyJob
    include Wurk::Job

    sidekiq_options retry: 5

    # 1s, 2s, 3s… so a retry is visible in the dashboard but clears quickly.
    sidekiq_retry_in { |count, _ex| count + 1 }

    def perform(*)
      raise 'flaky: transient failure' if rand < 0.5
    end
  end
end
