# frozen_string_literal: true

module Wurk
  # JSON APIs consumed by the React SPA. Each action returns a small,
  # well-shaped payload — no presenter bloat. SSE lives in #stream.
  class ApiController < ApplicationController
    def stats;     render json: {} end
    def queues;    render json: [] end
    def queue;     render json: {} end
    def retries;   render json: [] end
    def scheduled; render json: [] end
    def dead;      render json: [] end
    def processes; render json: [] end
    def batches;   render json: [] end
    def limiters;  render json: [] end
    def cron;      render json: [] end
    def metrics;   render json: {} end

    def stream
      response.headers["Content-Type"] = "text/event-stream"
      # TODO: push live updates via SSE.
      head :ok
    end
  end
end
