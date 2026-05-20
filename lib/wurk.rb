# frozen_string_literal: true

# Standalone entry point. Loading "wurk" must work without Rails.
# The engine and railtie live under "wurk/rails" and are only loaded
# when the host app opts in.

require_relative "wurk/version"
require_relative "wurk/configuration"
require_relative "wurk/redis_pool"
require_relative "wurk/middleware"
require_relative "wurk/middleware/chain"
require_relative "wurk/client"
require_relative "wurk/client/buffered"
require_relative "wurk/worker"
require_relative "wurk/job"
require_relative "wurk/queue"
require_relative "wurk/retry_set"
require_relative "wurk/scheduled_set"
require_relative "wurk/dead_set"
require_relative "wurk/stats"
require_relative "wurk/heartbeat"
require_relative "wurk/fetcher"
require_relative "wurk/fetcher/reliable"
require_relative "wurk/processor"
require_relative "wurk/manager"
require_relative "wurk/swarm"
require_relative "wurk/topology"
require_relative "wurk/lua"
require_relative "wurk/batch"
require_relative "wurk/batch/status"
require_relative "wurk/limiter"
require_relative "wurk/cron"
require_relative "wurk/leader"
require_relative "wurk/unique"
require_relative "wurk/encryption"
require_relative "wurk/metrics"
require_relative "wurk/metrics/statsd"
require_relative "wurk/metrics/history"
require_relative "wurk/compat"

module Wurk
  class Error < StandardError; end

  class << self
    def configure_server(&block)
      configuration.configure_server(&block)
    end

    def configure_client(&block)
      configuration.configure_client(&block)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def redis(&block)
      configuration.redis_pool.with(&block)
    end

    def logger
      configuration.logger
    end
  end
end
