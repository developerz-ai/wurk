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
  #
  # `max_job_age:` (`--max-job-age N`, opt-in) also fails when a job on this
  # host has been running for N seconds or more: a wedged processor keeps the
  # heartbeat thread beating, so the beat alone cannot catch it. Set N above
  # your longest legitimate job.
  class HealthProbe
    HEALTHY = 0
    UNHEALTHY = 1
    DEFAULT_WINDOW = 60

    # At most connect + two round trips: about 2s in all against a hung server.
    CLIENT_LIMITS = { connect_timeout: 0.5, read_timeout: 0.6, write_timeout: 0.6, reconnect_attempts: 0 }.freeze

    # The last field of a heartbeat work entry; see Metrics::Prometheus.
    RUN_AT_RE = /"run_at":(\d+(?:\.\d+)?)\}\z/

    def initialize(config, window: DEFAULT_WINDOW, min: 1, strict: false, max_job_age: nil,
                   hostname: Component.hostname, out: $stdout)
      @config = config
      @window = window
      @max_job_age = max_job_age
      @min = min
      @strict = strict
      @prefix = "#{hostname}:"
      @out = out
    end

    def call
      beats, run_ats = read_local
      fresh = fresh_count(beats)
      @out.puts "wurk health: #{fresh} process(es) on this host beat within #{@window}s (need #{@min})"
      return UNHEALTHY if fresh < @min

      jobs_within_age?(run_ats) ? HEALTHY : UNHEALTHY
    rescue RedisClient::Error, ConnectionPool::TimeoutError => e
      @out.puts "wurk health: cannot read Redis (#{e.class}: #{e.message})"
      @strict ? UNHEALTHY : HEALTHY
    end

    private

    def fresh_count(beats)
      now = ::Time.now.to_f
      beats.count { |beat| beat && now - beat.to_f < @window }
    end

    def jobs_within_age?(run_ats)
      return true unless @max_job_age

      oldest = run_ats.min
      age = oldest ? (::Time.now.to_f - oldest).round : 0
      return true if age < @max_job_age

      @out.puts "wurk health: a job on this host has been running for #{age}s (limit #{@max_job_age}s)"
      false
    end

    # [beat per local process, run_at of every job they are running]. The work
    # hashes are read only when `max_job_age` asks for them.
    def read_local
      client = build_client
      ids = client.call('SMEMBERS', Keys::PROCESSES).select { |id| id.start_with?(@prefix) }
      return [[], []] if ids.empty?

      replies = client.pipelined { |pipe| queue_reads(pipe, ids) }
      [replies.first(ids.size), run_ats(replies.drop(ids.size))]
    ensure
      client&.close
    end

    def queue_reads(pipe, ids)
      ids.each { |id| pipe.call('HGET', id, 'beat') }
      ids.each { |id| pipe.call('HVALS', "#{id}:work") } if @max_job_age
    end

    def run_ats(work_hashes)
      work_hashes.flatten.filter_map { |work| work[RUN_AT_RE, 1]&.to_f }
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
