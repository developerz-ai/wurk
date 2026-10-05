# frozen_string_literal: true

# Error reporting for the public demo (developerz-ai/infrastructure#502). Off
# unless the deployment sets WURK_DEMO_REPORT_ERRORS=1; SENTRY_DSN is injected
# by the cluster.
if ENV["WURK_DEMO_REPORT_ERRORS"] == "1"
  require "sentry-ruby"
  require "sentry-rails"
  require "wurk/sentry"

  # BrokenJob and FlakyWebhookJob fail on purpose so the Dead and Retries pages
  # are never empty. Reporting them would bury every real error under a steady
  # stream of intended ones.
  intentional_failures = %w[BrokenJob FlakyWebhookJob].freeze

  Sentry.init do |config|
    config.dsn = ENV.fetch("SENTRY_DSN", nil)
    # Synchronous sends: the worker initializes Sentry in the swarm parent and
    # then forks, and the SDK's background thread pool does not survive a fork.
    config.background_worker_threads = 0
    config.before_send = lambda do |event, _hint|
      job_class = event.contexts.dig(Wurk::Sentry::JobContext::CONTEXT_KEY, "class")
      intentional_failures.include?(job_class) ? nil : event
    end
  end

  # Straight onto the chain for the same reason the History middleware is in
  # wurk.rb: the worker boots with server? == false, so configure_server never runs.
  Wurk::Sentry.install!(Wurk.configuration)
end
