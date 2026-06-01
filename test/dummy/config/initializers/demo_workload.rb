# frozen_string_literal: true

# Auto-start the demo workload generator in a background thread when WURK_DEMO=1.
#
# Gated to a non-forking process (WURK_DISABLED=1 — e.g. the web/dashboard
# process): the generator holds a Redis connection, and a swarm fork must never
# inherit a live socket (CLAUDE.md boot order). The worker swarm runs as its own
# process and drains the traffic. For a dedicated process, use `rails demo:workload`.
if ENV['WURK_DEMO'] == '1'
  # Worker side: record per-job history so the dashboard's throughput/failures
  # charts have data (the History middleware is opt-in). configure_server only
  # fires in a worker/server process, so it's a no-op in the web process.
  Wurk.configure_server do |config|
    config.server_middleware.add(Wurk::Metrics::History)
  end

  # Web side (non-forking process — WURK_DISABLED=1): drive the traffic
  # generator in a background thread. Gated off the swarm so the generator's
  # Redis connection can never be inherited across a fork (CLAUDE.md boot order).
  if ENV['WURK_DISABLED'] == '1' && !Rails.env.test?
    Rails.application.config.after_initialize do
      Thread.new do
        Thread.current.name = 'demo-workload'
        Demo::Workload.new(logger: Rails.logger).run
      rescue StandardError => e
        Rails.logger.error("[demo] workload thread crashed: #{e.class}: #{e.message}")
      end
    end
  end
end
