# frozen_string_literal: true

require 'rack'
require_relative 'endpoints'
require_relative '../asset_mount'

module Wurk
  class Web
    module Dashboard
      # The dashboard under the standalone Rack mount (`run Sidekiq::Web`): the
      # same paths the engine draws in config/routes.rb, mapped to the
      # standalone endpoints. test/unit/web_dashboard_routes_test.rb holds this
      # table and the engine's routes to the same list.
      module Routes
        API = [
          ['GET', '/api/meta', :meta], ['GET', '/api/stats', :stats], ['GET', '/api/queues', :queues],
          ['GET', '/api/queues/:name', :queue], ['POST', '/api/queues/:name/clear', :clear_queue],
          ['POST', '/api/queues/:name/delete', :delete_queue_job], ['POST', '/api/queues/:name/pause', :pause_queue],
          ['POST', '/api/queues/:name/unpause', :unpause_queue],
          ['GET', '/api/retries', :retries], ['POST', '/api/retries', :retries_bulk],
          ['POST', '/api/retries/all/:cmd', :retries_all], ['POST', '/api/retries/:key', :retry_job],
          ['GET', '/api/retries/:key', :retry_entry],
          ['GET', '/api/scheduled', :scheduled], ['POST', '/api/scheduled', :scheduled_bulk],
          ['POST', '/api/scheduled/all/:cmd', :scheduled_all], ['POST', '/api/scheduled/:key', :scheduled_job],
          ['GET', '/api/scheduled/:key', :scheduled_entry],
          ['GET', '/api/dead', :dead], ['POST', '/api/dead', :dead_bulk], ['POST', '/api/dead/all/:cmd', :dead_all],
          ['POST', '/api/dead/:key', :dead_job], ['GET', '/api/dead/:key', :dead_entry],
          ['GET', '/api/processes', :processes], ['GET', '/api/workers', :workers],
          ['POST', '/api/busy/quiet', :quiet_process], ['POST', '/api/busy/stop', :stop_process],
          ['GET', '/api/flows', :flows], ['GET', '/api/flows/:fid', :flow],
          ['POST', '/api/flows/:fid/abandon', :abandon_flow],
          ['GET', '/api/batches', :batches], ['GET', '/api/batches/:bid', :batch],
          ['GET', '/api/limiters', :limiters], ['POST', '/api/limiters/:name/reset', :reset_limiter],
          ['GET', '/api/cron', :cron], ['POST', '/api/cron/:lid/pause', :pause_cron],
          ['POST', '/api/cron/:lid/unpause', :unpause_cron], ['POST', '/api/cron/:lid/enqueue', :enqueue_cron],
          ['GET', '/api/cron/:lid/history', :cron_history],
          ['GET', '/api/metrics', :metrics], ['GET', '/api/metrics/:klass', :metrics_for_job],
          ['GET', '/api/history/snapshots', :history_snapshots], ['GET', '/api/history/:bucket', :history],
          ['GET', '/api/queue-history/:bucket', :queue_history], ['GET', '/api/search', :search],
          ['GET', '/api/profiles', :profiles], ['GET', '/api/stream', :stream]
        ].map { |verb, path, action| [verb, path, ApiEndpoint, action] }

        PROFILES = [
          ['GET', '/profiles/:key/data', ProfilesEndpoint, :data],
          ['GET', '/profiles/:key', ProfilesEndpoint, :show],
          ['POST', '/profiles/:key', ProfilesEndpoint, :upload]
        ].freeze

        TABLE = (API + PROFILES).map do |verb, path, endpoint, action|
          [verb, path.split('/').reject(&:empty?), endpoint, action].freeze
        end.freeze

        EXTENSION_VERBS = %w[GET POST PUT PATCH DELETE].freeze
        # A path ending in a static-file extension is never a client route, so
        # a stale asset or source-map URL 404s rather than answering 200 HTML.
        STATIC_FILE = /\.(?:js|mjs|css|map|json|png|jpe?g|gif|svg|ico|webp|woff2?|ttf|txt)\z/i

        class << self
          # A Rack triple, or nil when the path is not the dashboard's.
          def call(env)
            verb = env['REQUEST_METHOD'] == 'HEAD' ? 'GET' : env['REQUEST_METHOD']
            path = env['PATH_INFO'].to_s
            return asset(env) if path.start_with?("#{AssetMount::PREFIX}/")

            endpoint, action, params = match(verb, segments(path))
            return endpoint.call(env, action, params) if endpoint

            extension(env, verb, path) || shell(env, verb, path)
          end

          def match(verb, parts)
            TABLE.each do |route_verb, pattern, endpoint, action|
              next unless route_verb == verb && pattern.size == parts.size

              params = bind(pattern, parts)
              return [endpoint, action, params] if params
            end
            nil
          end

          private

          def segments(path) = path.split('/').reject(&:empty?).map { |seg| ::Rack::Utils.unescape_path(seg) }

          def bind(pattern, parts)
            pattern.each_with_index.with_object({}) do |(seg, i), params|
              if seg.start_with?(':') then params[seg[1..]] = parts[i]
              elsif seg != parts[i] then return nil
              end
            end
          end

          def asset(env)
            @assets ||= AssetMount.new(->(_env) { [404, {}, []] })
            response = @assets.call(env)
            response[0] == 404 ? nil : response
          end

          # `ext/:name(/*subpath)` and `ext-assets/:name/*file`, as the engine
          # draws them.
          def extension(env, verb, path)
            parts = segments(path)
            return unless parts.size >= 2

            case parts.first
            when 'ext'
              return unless EXTENSION_VERBS.include?(verb)

              params = { 'name' => parts[1], 'subpath' => parts[2..].join('/') }
              ExtensionsEndpoint.call(env, :show, params)
            when 'ext-assets'
              return unless verb == 'GET' && parts.size >= 3

              ExtensionsEndpoint.call(env, :asset, { 'name' => parts[1], 'file' => parts[2..].join('/') })
            end
          end

          # Every other GET a browser makes is a client route of the SPA, but
          # an unknown `/api/...` path is a missing endpoint, not a page.
          def shell(env, verb, path)
            return unless verb == 'GET' && !path.match?(STATIC_FILE) && html?(env['HTTP_ACCEPT'])
            return if path == '/api' || path.start_with?('/api/')

            ShellEndpoint.call(env, :index)
          end

          def html?(accept)
            accept.to_s.empty? || accept.include?('text/html') || accept.include?('*/*')
          end
        end
      end
    end
  end
end
