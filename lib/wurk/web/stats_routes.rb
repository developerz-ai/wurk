# frozen_string_literal: true

require 'json'
require 'rack/request'
require_relative 'pool_scope'

module Wurk
  class Web
    # Sidekiq Web's machine-readable routes (spec §25.4): `HEAD /` (a Redis
    # round trip, for uptime checks), `GET /stats`, `GET /stats/queues`, and
    # `GET /dashboard/stats` redirecting to `/stats`. Uptime probes and scripts
    # written against `/sidekiq/stats` read these shapes, so they are
    # upstream's, not the SPA's `/api/stats`.
    #
    # Plain Rack, so it serves both the engine (config/routes.rb points these
    # paths here, behind the engine's gates) and the Rails-free
    # `run Sidekiq::Web` (Web.call dispatches here, behind the same gates).
    module StatsRoutes
      REDIS_KEYS = %w[redis_version uptime_in_days connected_clients used_memory_human used_memory_peak_human].freeze
      READ_METHODS = %w[GET HEAD].freeze
      JSON_HEADERS = { 'content-type' => 'application/json', 'cache-control' => 'private, no-store' }.freeze

      class << self
        def call(env)
          serve(env) || [404, { 'content-type' => 'text/plain' }, ['Not Found']]
        end

        # The response for a path this module owns, or nil.
        def serve(env)
          method = env['REQUEST_METHOD']
          return unless READ_METHODS.include?(method)

          path = env['PATH_INFO'].to_s
          return head_root if method == 'HEAD' && ['', '/'].include?(path)

          case path
          when '/stats' then json(stats)
          when '/stats/queues' then json(PoolScope.scope { Wurk::Stats.new.queues })
          when '/dashboard/stats' then redirect(env)
          end
        end

        private

        # Errors propagate: a probe must see a failure when Redis is down.
        def head_root
          PoolScope.scope { Wurk.redis(idempotent: true) { |conn| conn.call('LLEN', 'queue:default') } }
          [200, { 'content-type' => 'text/html' }, []]
        end

        def stats
          PoolScope.scope do
            s = Wurk::Stats.new
            {
              sidekiq: {
                processed: s.processed, failed: s.failed, busy: s.workers_size,
                processes: s.processes_size, enqueued: s.enqueued, scheduled: s.scheduled_size,
                retries: s.retry_size, dead: s.dead_size, default_latency: s.default_queue_latency
              },
              redis: redis_stats,
              server_utc_time: ::Time.now.utc.strftime('%H:%M:%S UTC')
            }
          end
        end

        def redis_stats
          info = Wurk.redis_pool.info
          info.slice(*REDIS_KEYS).merge('store_name' => store_name(info), 'store_version' => store_version(info))
        end

        def store_name(info)
          return 'Dragonfly' if info.key?('dragonfly_version')
          return 'Valkey' if info.key?('valkey_version')

          'Redis'
        end

        def store_version(info)
          info['dragonfly_version'] || info['valkey_version'] || info['redis_version']
        end

        def json(payload)
          [200, JSON_HEADERS.dup, [::JSON.generate(payload)]]
        end

        def redirect(env)
          request = ::Rack::Request.new(env)
          [302, { 'location' => "#{request.base_url}#{env['SCRIPT_NAME']}/stats" }, []]
        end
      end
    end
  end
end
