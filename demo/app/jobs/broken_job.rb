# frozen_string_literal: true

# Always fails with no retries → lands in the Dead set immediately, so that view
# is never empty.
class BrokenJob
  include Sidekiq::Job

  sidekiq_options retry: 0

  def perform
    raise "broken job: permanent failure"
  end
end
