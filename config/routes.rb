# frozen_string_literal: true

Wurk::Engine.routes.draw do
  root to: "dashboard#index"

  # JSON APIs consumed by the SPA. Nested under whatever mount the host chose.
  scope :api, defaults: { format: :json } do
    get  "stats",            to: "api#stats"
    get  "queues",           to: "api#queues"
    get  "queues/:name",     to: "api#queue",       as: :api_queue
    get  "retries",          to: "api#retries"
    get  "scheduled",        to: "api#scheduled"
    get  "dead",             to: "api#dead"
    get  "processes",        to: "api#processes"
    get  "batches",          to: "api#batches"
    get  "limiters",         to: "api#limiters"
    get  "cron",             to: "api#cron"
    get  "metrics",          to: "api#metrics"
    get  "stream",           to: "api#stream" # SSE
  end

  # SPA catch-all — let React Router handle the rest.
  get "*path", to: "dashboard#index", constraints: ->(req) { req.format == :html }
end
