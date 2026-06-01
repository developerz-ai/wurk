# frozen_string_literal: true

module Demo
  # Runs its work through a bucket limiter so the Limiters widget shows live
  # usage. OverLimit is swallowed here (the demo just wants the counters to
  # move); in real code the limiter server middleware reschedules instead.
  class RateLimitedJob
    include Wurk::Job

    def perform(*)
      Demo::Workload.email_limiter.within_limit { sleep(rand * 0.01) }
    rescue Wurk::Limiter::OverLimit
      # Expected under load — the bucket is intentionally small.
    end
  end
end
