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

    private

    def scope_web_redis_pool(&) = ::Wurk::Web::PoolScope.scope(&)
  end
end
