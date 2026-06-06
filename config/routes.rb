# frozen_string_literal: true

Wurk::Engine.routes.draw do
  root to: 'dashboard#index'

  # JSON APIs consumed by the SPA. Nested under whatever mount the host chose.
  scope :api, defaults: { format: :json } do
    get  'meta',             to: 'api#meta'
    get  'stats',            to: 'api#stats'
    get  'queues',           to: 'api#queues'
    get  'queues/:name',     to: 'api#queue', as: :api_queue, constraints: { name: %r{[^/]+} }
    post 'queues/:name/clear',  to: 'api#clear_queue',     as: :api_clear_queue,     constraints: { name: %r{[^/]+} }
    post 'queues/:name/delete', to: 'api#delete_queue_job', as: :api_delete_queue_job, constraints: { name: %r{[^/]+} }

    # Job-set mutations (retry/delete/kill/requeue/clear). The SPA posts to
    # these; the Authorization middleware 403s every non-GET in read-only mode,
    # so they need no extra guard. `:key` is "<score>|<jid>" (Wurk::SortedEntry#id);
    # `all/:cmd` operates over the whole set; the bare collection POST is a bulk
    # action over `keys[]`. Spec: docs/target/sidekiq-free.md §25.4.
    # `all/:cmd` is intentionally unconstrained: the controller validates `:cmd`
    # against the per-set whitelist and returns a JSON 400 for an unknown action,
    # matching the single/bulk contract. A route-level constraint would turn that
    # into a 404 route miss instead.
    get  'retries',          to: 'api#retries'
    post 'retries',          to: 'api#retries_bulk',   as: :api_retries_bulk
    post 'retries/all/:cmd', to: 'api#retries_all',    as: :api_retries_all
    post 'retries/:key',     to: 'api#retry_job',      as: :api_retry_job,   constraints: { key: %r{[^/]+} }
    get  'scheduled',        to: 'api#scheduled'
    post 'scheduled',          to: 'api#scheduled_bulk', as: :api_scheduled_bulk
    post 'scheduled/all/:cmd', to: 'api#scheduled_all',  as: :api_scheduled_all
    post 'scheduled/:key',     to: 'api#scheduled_job',  as: :api_scheduled_job, constraints: { key: %r{[^/]+} }
    get  'dead',             to: 'api#dead'
    post 'dead',             to: 'api#dead_bulk',      as: :api_dead_bulk
    post 'dead/all/:cmd',    to: 'api#dead_all',       as: :api_dead_all
    post 'dead/:key',        to: 'api#dead_job',       as: :api_dead_job, constraints: { key: %r{[^/]+} }
    get  'processes',        to: 'api#processes'
    get  'batches',          to: 'api#batches'
    get  'batches/:bid',     to: 'api#batch', as: :api_batch
    get  'limiters',         to: 'api#limiters'
    post 'limiters/:name/reset', to: 'api#reset_limiter', as: :api_reset_limiter
    get  'cron',             to: 'api#cron'
    post 'cron/:lid/pause',  to: 'api#pause_cron', as: :api_pause_cron
    post 'cron/:lid/unpause', to: 'api#unpause_cron', as: :api_unpause_cron
    post 'cron/:lid/enqueue', to: 'api#enqueue_cron', as: :api_enqueue_cron
    get  'cron/:lid/history', to: 'api#cron_history', as: :api_cron_history
    get  'metrics',          to: 'api#metrics'
    get  'metrics/:klass',   to: 'api#metrics_for_job', as: :api_metrics_for_job, constraints: { klass: %r{[^/]+} }
    get  'history/:bucket',  to: 'api#history', as: :api_history
    get  'search',           to: 'api#search'
    get  'stream',           to: 'api#stream' # SSE
  end

  # SPA catch-all — let React Router handle the rest.
  get '*path', to: 'dashboard#index', constraints: ->(req) { req.format == :html }
end
