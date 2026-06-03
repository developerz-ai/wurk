# frozen_string_literal: true

# Wiring for the public demo.

# Public dashboard is read-only: every mutating request (retry/kill/requeue/
# pause/clear) returns 403 at the middleware layer, and the SPA hides the
# destructive actions. WURK_WEB_READ_ONLY=1 in the image sets this too; doing it
# here as well makes the demo read-only even if someone runs it without the env.
Wurk::Web.configure do |c|
  c.read_only = true
  c.read_only_message = "This is a public demo — actions are disabled."
end

# Enterprise uniqueness — installs the client+server middleware so
# `sidekiq_options unique_for:` (SendReceiptJob) actually de-dupes.
Sidekiq::Enterprise.unique!

# Worker side: record per-job history so the throughput/failures charts have
# data (the History middleware is opt-in). Only fires in a worker/server process.
if ENV["WURK_DEMO"] == "1"
  Wurk.configure_server do |config|
    config.server_middleware.add(Wurk::Metrics::History)
  end

  # Web side (non-forking process): run the traffic producer in a background
  # thread. Gated off the swarm so its Redis connection can't be inherited
  # across a fork (CLAUDE.md boot order). The worker process drains the traffic.
  if ENV["WURK_DISABLED"] == "1"
    Rails.application.config.after_initialize do
      Thread.new do
        Thread.current.name = "demo-producer"
        DemoProducer.new(logger: Rails.logger).run
      rescue StandardError => e
        Rails.logger.error("[demo] producer thread crashed: #{e.class}: #{e.message}")
      end
    end
  end
end
