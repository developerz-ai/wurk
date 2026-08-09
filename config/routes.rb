# frozen_string_literal: true

Wurk::Engine.routes.draw do
  root to: 'dashboard#index'

  # JSON APIs consumed by the SPA. Nested under whatever mount the host chose.
  scope :api, defaults: { format: :json } do
    get  'meta',             to: 'api#meta'
    get  'stats',            to: 'api#stats'
    get  'queues',           to: 'api#queues'
    get  'queues/:name',     to: 'api#queue', as: :api_queue, constraints: { name: %r{[^/]+} }
    post 'queues/:name/clear',  to: 'api#clear_queue', as: :api_clear_queue, constraints: { name: %r{[^/]+} }
    post 'queues/:name/delete', to: 'api#delete_queue_job', as: :api_delete_queue_job, constraints: { name: %r{[^/]+} }
    # Per-queue Pause/Unpause (Pro §6, §10.1): toggles membership of the `paused`
    # SET that fetchers consult. Read-only mode 403s these via Authorization.
    post 'queues/:name/pause',   to: 'api#pause_queue',   as: :api_pause_queue,   constraints: { name: %r{[^/]+} }
    post 'queues/:name/unpause', to: 'api#unpause_queue', as: :api_unpause_queue, constraints: { name: %r{[^/]+} }

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
    post 'retries/:key',     to: 'api#retry_job',      as: :api_retry_job, constraints: { key: %r{[^/]+} }
    get  'scheduled',        to: 'api#scheduled'
    post 'scheduled',          to: 'api#scheduled_bulk', as: :api_scheduled_bulk
    post 'scheduled/all/:cmd', to: 'api#scheduled_all',  as: :api_scheduled_all
    post 'scheduled/:key',     to: 'api#scheduled_job',  as: :api_scheduled_job, constraints: { key: %r{[^/]+} }
    get  'dead',             to: 'api#dead'
    post 'dead',             to: 'api#dead_bulk',      as: :api_dead_bulk
    post 'dead/all/:cmd',    to: 'api#dead_all',       as: :api_dead_all
    post 'dead/:key',        to: 'api#dead_job',       as: :api_dead_job, constraints: { key: %r{[^/]+} }
    get  'processes',        to: 'api#processes'
    get  'workers',          to: 'api#workers'
    # Busy-page process control (quiet/stop). `identity` rides in the body (it
    # contains ':' and '.', awkward as a path segment); absent or "all" signals
    # every live process. Read-only mode 403s these via the Authorization
    # middleware. Spec: docs/target/sidekiq-free.md §25.4 (POST /busy).
    post 'busy/quiet', to: 'api#quiet_process', as: :api_quiet_process
    post 'busy/stop',  to: 'api#stop_process',  as: :api_stop_process
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
    get  'history/snapshots', to: 'api#history_snapshots', as: :api_history_snapshots
    get  'history/:bucket', to: 'api#history', as: :api_history
    get  'queue-history/:bucket', to: 'api#queue_history', as: :api_queue_history
    get  'search',           to: 'api#search'
    get  'profiles',         to: 'api#profiles'
    get  'stream',           to: 'api#stream' # SSE
  end

  # The machine-facing HTTP API (lib/wurk/api/) — mount mode 1 of three. An app
  # that already mounts the engine gets it at `<mount>/api/v1` for free once a
  # token exists; `Wurk::API.serves?` decides per request, so with none the
  # constraint fails, Rails falls through, and there is no surface to find. It
  # shares the /api prefix with the dashboard's own JSON API above; the
  # constraint — not the declaration order — is what keeps those matching.
  #
  # Nested here it also inherits the engine's middleware — the host's
  # `Wurk::Web.use` chain and the read-only gate — so a dashboard behind Devise
  # keeps gating this path too. A machine client that cannot pass a browser
  # login wants mode 2 instead: `mount Wurk::API => '/wurk-api'` in the host's
  # own routes, declared BEFORE the engine when its path extends the engine's —
  # Rails matches a mounted app by bare string prefix, so `mount Wurk::Engine =>
  # '/wurk'` declared first swallows every `/wurk-api/...` request.
  mount Wurk::API => Wurk::API::ENGINE_MOUNT, constraints: ->(request) { Wurk::API.serves?(request.path_info) }

  # Profiles (v8.0+) — not under /api: `:key/data` streams the gzipped gecko
  # blob with a gzip Content-Encoding, and `:key` POST-uploads the profile to
  # the Firefox profiler then 302s to its public view. `:key` is "<token>-<jid>".
  # The `/data` route is declared first so it wins over the bare `:key` match.
  # Spec: docs/target/sidekiq-free.md §25.4.
  get 'profiles/:key/data', to: 'profiles#data', as: :profile_data, constraints: { key: %r{[^/]+} }
  get 'profiles/:key',      to: 'profiles#show', as: :profile,      constraints: { key: %r{[^/]+} }

  # Third-party Web extensions (#187): server-rendered route + assets. The SPA's
  # Extension page fetches `ext/:name/<subpath>` and embeds the returned HTML;
  # `format: false` keeps dots in subpaths/filenames out of Rails' format logic.
  # An /ext URL with no matching registered extension falls through to the SPA
  # shell inside the controller (it's the SPA's own /ext/:tab client route).
  match 'ext/:name(/*subpath)', to: 'extensions#show', via: %i[get post put patch delete], as: :extension,
                                format: false, defaults: { subpath: '' }, constraints: { name: %r{[^/]+} }
  get 'ext-assets/:name/*file', to: 'extensions#asset', as: :extension_asset,
                                format: false, constraints: { name: %r{[^/]+} }

  # SPA catch-all — let the SolidJS router handle the rest.
  get '*path', to: 'dashboard#index', constraints: ->(req) { req.format == :html }
end
