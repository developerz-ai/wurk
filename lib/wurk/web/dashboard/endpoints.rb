# frozen_string_literal: true

require_relative 'controller'
require_relative '../pool_scope'
require_relative 'api_actions'
require_relative 'extension_actions'
require_relative 'profile_actions'
require_relative 'shell'
require_relative 'stats_tick'
require_relative 'stream_concurrency_guard'

module Wurk
  class Web
    module Dashboard
      # The standalone mount's controllers: the engine's actions over
      # Dashboard::Controller instead of ActionController.
      class ShellEndpoint < Controller
        def index
          render html: Shell.new(request, asset_base: "#{request.script_name.chomp('/')}#{AssetMount::PREFIX}").html
        end
      end

      class ApiEndpoint < Controller
        include ApiActions

        # The engine streams through ActionController::Live; here the body is
        # the stream, written as the server iterates it. The slot is held from
        # here until the server closes the body. Past the cap: 503, as the
        # engine answers.
        def stream
          unless StreamConcurrencyGuard.acquire
            response.headers['Retry-After'] = StreamConcurrencyGuard::RETRY_AFTER_SECONDS.to_s
            return head(:service_unavailable)
          end

          tick, max_dur = stream_window
          finish(200, 'text/event-stream', '')
          @result[1].merge!('cache-control' => 'no-cache', 'x-accel-buffering' => 'no')
          @result[2] = StatsStream.new(tick, max_dur)
        end
      end

      class ProfilesEndpoint < Controller
        include ProfileActions

        before_action :require_listed_profile
      end

      class ExtensionsEndpoint < ShellEndpoint
        include ExtensionActions
      end

      # `/api/stream`'s body: one `event: stats` per tick until the deadline,
      # in the bytes ActionController::Live::SSE writes for the engine.
      class StatsStream
        RETRY_MS = (ApiActions::STREAM_TICK_SECONDS * 1000).to_i

        def initialize(tick, max_duration)
          @tick = tick
          @max_duration = max_duration
        end

        # The server iterates the body after the Rack app returned, outside
        # the web pool scope it set, so each read re-enters it.
        def each
          deadline = monotime + @max_duration
          loop do
            yield event('stats', PoolScope.scope { StatsTick.payload })
            break if monotime >= deadline

            sleep @tick
          end
        rescue *::Wurk::Configuration::REDIS_ERROR_CLASSES => e
          ::Wurk.logger.warn("wurk web: stream redis unavailable (#{e.class}: #{e.message})")
          yield event('error', { error: 'redis_unavailable' })
        end

        def close
          StreamConcurrencyGuard.release
        end

        private

        def event(name, payload)
          "retry: #{RETRY_MS}\nevent: #{name}\ndata: #{Dashboard.json(payload)}\n\n"
        end

        def monotime = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
