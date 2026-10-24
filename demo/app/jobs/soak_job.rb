# frozen_string_literal: true

class SoakJob
  include Wurk::Job

  TAG = "demo-soak"
  TTL = 300
  sidekiq_options queue: "low", retry: 2, dead: false, tags: [TAG]
  sidekiq_retry_in { 1 }

  def self.record(token, event)
    Wurk.redis { |c| c.call("SET", "demo-soak:#{token}:#{event}", "1", "EX", TTL) }
  end

  def perform(token)
    # Fixed CPU work, no external services or application data mutations.
    100.times.reduce(0) { |sum, n| sum ^ n }
    SoakJob.record(token, self.class.name)
  end

  class RetryOnce < SoakJob
    def perform(token)
      first = Wurk.redis { |c| c.call("SET", "demo-soak:#{token}:attempt", "1", "NX", "EX", TTL) }
      raise "intentional demo soak retry" if first == "OK"

      super
    end
  end

  class Cron < SoakJob; end
  class BatchMember < SoakJob; end

  class Unique < SoakJob
    sidekiq_options unique_for: 30
  end

  class BucketLimited < SoakJob
    def perform(token)
      Wurk::Limiter.bucket("demo-soak", 2, :minute, wait_timeout: 0,
        backoff: ->(*) { 1 }, reschedule: 2, ttl: TTL).within_limit { super }
    end
  end

  class Callback
    def on_complete(status, options)
      SoakJob.record(options.fetch("token"), "complete:#{status.bid}")
    end

    def on_success(status, options)
      SoakJob.record(options.fetch("token"), "success:#{status.bid}")
    end
  end

  class Tagging
    def call(_worker, job, _queue, *_pool)
      klass = job["class"].to_s
      family = klass == "SoakJob" || klass.start_with?("SoakJob::")
      callback = %w[Wurk::Batch::CallbackJob Sidekiq::Batch::CallbackJob].include?(klass) &&
        job["args"].is_a?(Array) && job["args"][1].to_s.split("#").first == "SoakJob::Callback"
      if family || callback
        job["tags"] = (Array(job["tags"]) + [TAG]).uniq
        # Do not change retry policy on wrappers belonging to other producers.
        job["retry"] = 2
        job["dead"] = false
      end
      yield
    end
  end

  class SentryTagging
    def call(_worker, job, _queue)
      if Array(job["tags"]).include?(TAG) && Wurk::Sentry.enabled?
        # This must remain on Wurk's scope until its outer rescue captures.
        ::Sentry.configure_scope { |scope| scope.set_tag(TAG, true) }
      end
      yield
    end
  end
end
