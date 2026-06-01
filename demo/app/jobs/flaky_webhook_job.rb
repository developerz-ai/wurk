# frozen_string_literal: true

# Fails ~40% of the time on a short backoff, so the Retries page stays populated
# and most eventually recover.
class FlakyWebhookJob
  include Sidekiq::Job

  sidekiq_options retry: 5
  sidekiq_retry_in { |count, _ex| count + 1 } # 1s,2s,3s…

  def perform
    raise "flaky webhook: transient failure" if rand < 0.4
  end
end
