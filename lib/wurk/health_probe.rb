# frozen_string_literal: true

require_relative 'component'
require_relative 'keys'

module Wurk
  # `wurk health`: an exec-style liveness probe, for a pod with no HTTP port. It
  # boots no application, so it is fast and only needs to reach Redis (REDIS_URL
  # or --redis-url). Passes when enough processes on this host have a recent
  # heartbeat.
  #
  # A Redis it cannot reach is not this pod's fault, and restarting workers does
  # not bring Redis back, so that passes too unless `--strict`.
  class HealthProbe
    HEALTHY = 0
    UNHEALTHY = 1
    DEFAULT_WINDOW = 60

    # At most connect + two round trips: about 2s in all against a hung server.
    CLIENT_LIMITS = { connect_timeout: 0.5, read_timeout: 0.6, write_timeout: 0.6, reconnect_attempts: 0 }.freeze

    def initialize(config, window: DEFAULT_WINDOW, min: 1, strict: false, hostname: Component.hostname, out: $stdout)
      @config = config
      @window = window
      @min = min
      @strict = strict
      @prefix = "#{hostname}:"
      @out = out
    end

    def call
      fresh = fresh_processes
      @out.puts "wurk health: #{fresh} process(es) on this host beat within #{@window}s (need #{@min})"
      fresh >= @min ? HEALTHY : UNHEALTHY
    rescue RedisClient::Error, ConnectionPool::TimeoutError => e
      @out.puts "wurk health: cannot read Redis (#{e.class}: #{e.message})"
      @strict ? UNHEALTHY : HEALTHY
    end

    private

    def fresh_processes
      now = ::Time.now.to_f
      read_local_beats.count { |beat| beat && now - beat.to_f < @window }
    end

    def read_local_beats
      client = build_client
      ids = client.call('SMEMBERS', Keys::PROCESSES).select { |id| id.start_with?(@prefix) }
      ids.empty? ? [] : client.pipelined { |pipe| ids.each { |id| pipe.call('HGET', id, 'beat') } }
    ensure
      client&.close
    end

    # Directly on redis-client rather than through RedisPool: the pool's retries
    # and backoff are right for a worker and fatal here. They took 4s on a refused
    # connection and 19s on a hung server, past a kubelet's probe timeout, so a
    # store outage restarted every pod.
    def build_client
      opts = RedisOptions.normalize(@config.redis_config).except(*RedisOptions::POOL_KEYS).merge(CLIENT_LIMITS)
      (RedisOptions.sentinel?(opts) ? RedisClient.sentinel(**opts) : RedisClient.config(**opts)).new_client
    end
  end
end
