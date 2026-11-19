# frozen_string_literal: true

require 'wurk/web/dashboard/api_actions'
require 'wurk/web/dashboard/stream_concurrency_guard'

module Wurk
  # The engine's transport for the dashboard JSON API: the actions live in
  # Wurk::Web::Dashboard::ApiActions, shared with the standalone Rack mount.
  class ApiController < ApplicationController
    include ActionController::Live
    # The SPA is a token-less JSON client; SameOriginGuard supplies Sidekiq's
    # same-origin CSRF defense (spec §25.1) so every mutating endpoint is
    # protected — GET reads (incl. #stream SSE) stay reachable.
    include SameOriginGuard
    # Bounds concurrent SSE streams per process (503 past the cap) so stale
    # dashboard tabs can't pin every Puma thread. Provides #with_stream_slot.
    include ::Wurk::Web::Dashboard::StreamConcurrencyGuard
    # Owns the #stream action's tick loop (headers, cadence, tear-down).
    include SseStreaming
    include ::Wurk::Web::Dashboard::ApiActions

    # SSE: one `event: stats` per tick with a fresh Stats snapshot. Caps at
    # `STREAM_MAX_DURATION` so a stale browser tab can't tie a Rails worker
    # forever; a stream that closes normally is reopened by EventSource after
    # the `retry:` interval sent below. Bounded per process by
    # StreamConcurrencyGuard so a burst of tabs can't pin every Puma thread.
    # Past the cap the answer is a 503, which EventSource treats as fatal and
    # whose Retry-After it cannot read: the SPA reopens it itself, backing off
    # from 3s and doubling to 30s (frontend/src/hooks/useSSE.ts).
    def stream
      with_stream_slot do
        stream_headers!
        tick, max_dur = stream_window
        sse = ::ActionController::Live::SSE.new(response.stream, retry: (STREAM_TICK_SECONDS * 1000).to_i)
        drive_stream(sse, tick, max_dur)
      end
    end
  end
end
