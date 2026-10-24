# frozen_string_literal: true

# Error reporting for the public demo (developerz-ai/infrastructure#502).
#
# On only when the deployment asks for it AND gives us somewhere to report to:
# WURK_DEMO_REPORT_ERRORS=1 plus SENTRY_DSN. The flag alone would boot the SDK
# with nowhere to send events; the DSN alone would report from a deployment
# that never opted in.
#
# The gate lives in DemoSentryPolicy, so this initializer and
# config/application.rb (which decides whether the SDK is loaded at all) can
# never disagree about it.
require_relative "../../lib/demo_sentry_policy"

if DemoSentryPolicy.enabled?
  require "wurk/sentry"

  Sentry.init do |config|
    config.dsn = DemoSentryPolicy.dsn
    # Synchronous sends: the worker initializes Sentry in the swarm parent and
    # then forks, and the SDK's background thread pool does not survive a fork.
    config.background_worker_threads = 0
    # The demo publishes nothing about who visited it.
    config.send_default_pii = false
    # BrokenJob and FlakyWebhookJob fail on purpose so the Dead and Retries
    # pages are never empty, and a soak run's events are load rather than
    # signal. The policy drops those, and scrubs credentials out of whatever
    # is left.
    config.before_send = DemoSentryPolicy.method(:before_send)
  end

  # Straight onto the chain for the same reason the History middleware is in
  # wurk.rb: the worker boots with server? == false, so configure_server never
  # runs.
  Wurk::Sentry.install!(Wurk.configuration)
end
