# frozen_string_literal: true

Wurk::Engine.routes.draw do
  root to: 'dashboard#index'

  # JSON APIs consumed by the SPA. Nested under whatever mount the host chose.
  scope :api, defaults: { format: :json } do
    get  'stats',            to: 'api#stats'
    get  'queues',           to: 'api#queues'
    get  'queues/:name',     to: 'api#queue', as: :api_queue
    get  'retries',          to: 'api#retries'
    get  'scheduled',        to: 'api#scheduled'
    get  'dead',             to: 'api#dead'
    get  'processes',        to: 'api#processes'
    get  'batches',          to: 'api#batches'
    get  'limiters',         to: 'api#limiters'
    post 'limiters/:name/reset', to: 'api#reset_limiter', as: :api_reset_limiter
    get  'cron',             to: 'api#cron'
    post 'cron/:lid/pause',  to: 'api#pause_cron', as: :api_pause_cron
    post 'cron/:lid/unpause', to: 'api#unpause_cron', as: :api_unpause_cron
    post 'cron/:lid/enqueue', to: 'api#enqueue_cron', as: :api_enqueue_cron
    get  'cron/:lid/history', to: 'api#cron_history', as: :api_cron_history
    get  'metrics',          to: 'api#metrics'
    get  'metrics/:klass',   to: 'api#metrics_for_job', as: :api_metrics_for_job, constraints: { klass: %r{[^/]+} }
    get  'search',           to: 'api#search'
    get  'stream',           to: 'api#stream' # SSE
  end

  # SPA catch-all — let React Router handle the rest.
  get '*path', to: 'dashboard#index', constraints: ->(req) { req.format == :html }
end
