# frozen_string_literal: true

require 'wurk/web'

module Wurk
  class ApplicationController < ::ActionController::Base
    protect_from_forgery with: :exception

    # Route every dashboard/API/SSE Redis read through the dedicated web pool
    # (disjoint from the worker pool, #101) so dashboard load can't exhaust the
    # connections a co-located worker needs. Wraps the whole action — including
    # the SSE stream, which ActionController::Live runs (filters and all) in a
    # spawned thread, so the thread-local set here still covers each tick's
    # checkout.
    around_action :scope_web_redis_pool

    # A blip/outage surfacing here is the *same* condition RedisPool already
    # retried and gave up on (its `on_error` hook already fired — #101).
    # Report it to the SPA as a structured, retryable 503 instead of letting
    # it fall through to Rails' generic 500 error page, which would leak a
    # backtrace and give the client nothing to branch on.
    rescue_from(*::Wurk::Configuration::REDIS_ERROR_CLASSES) { |ex| render_redis_unavailable(ex) }

    private

    def scope_web_redis_pool(&) = ::Wurk::Web::PoolScope.scope(&)

    def render_redis_unavailable(ex)
      logger.warn("wurk web: redis unavailable (#{ex.class}: #{ex.message})")
      render json: { error: 'redis_unavailable' }, status: :service_unavailable
    end
  end
end
