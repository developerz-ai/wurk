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

# Worker side: record per-job history so the Metrics throughput/failure charts
# have data (the History middleware is opt-in).
#
# Add it DIRECTLY to the server-middleware chain, not via `Wurk.configure_server`:
# that block only runs when `Wurk.configuration.server?` is true, but the demo
# worker boots via `bin/rails runner 'Wurk::Swarm.new…supervise'` where the
# initializer runs with server? == false, so the block was silently skipped and
# Metrics stayed empty (see #100). The swarm forks AFTER this initializer, so the
# children inherit the chain.
if ENV["WURK_DEMO"] == "1"
  unless Wurk.configuration.server_middleware.exists?(Wurk::Metrics::History)
    Wurk.configuration.server_middleware.add(Wurk::Metrics::History)
  end

  # DemoProducer registers cron jobs onto `high` (ThrottledApiJob) and `low`
  # (DailyReportJob), but the default capsule fetches `default` only — so those
  # two queues were produced into and never consumed. The hourly demo:reset
  # FLUSHDB hid it; when that CronJob started failing, `low` reached 598 jobs at
  # ~10h latency on the public dashboard. Set before the swarm is built: the
  # worker's `rails runner` reads Wurk.configuration.topology, which derives
  # from this capsule's queue_specs, and initializers run first.
  #
  # Order is strict priority, and it is also the thing the demo exists to show:
  # `high` drains before `default`, which drains before `low`.
  Wurk.configuration.queues = %w[high default low]

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
