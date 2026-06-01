# frozen_string_literal: true

# Runs its work through a bucket rate limiter (Enterprise parity), so the
# Limiters page shows live usage. OverLimit is swallowed here — the demo only
# wants the counters to move; real code would let the limiter reschedule.
class ThrottledApiJob
  include Sidekiq::Job

  def perform
    DemoProducer.api_limiter.within_limit { sleep(rand * 0.02) }
  rescue Wurk::Limiter::OverLimit
    # expected under load — the bucket is intentionally small
  end
end
