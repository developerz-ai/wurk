# frozen_string_literal: true

module Wurk
  class Web
    # Web UI configuration. Holds the authorization callback documented in
    # docs/target/sidekiq-ent.md §9.2 — a Rack-level hook called with
    # `(env, method, path)` per request. Truthy return proceeds; falsey
    # short-circuits to 403.
    #
    # Wurk ships the Ent feature in the free gem. No license check; the
    # block runs unconditionally when present.
    #
    # Example:
    #
    #   Wurk::Web.configure do |c|
    #     c.authorization do |env, method, _path|
    #       user = env['warden']&.user
    #       method == 'GET' ? user&.support? || user&.admin? : user&.admin?
    #     end
    #   end
    #
    # When no block is registered, every request is authorized (matches
    # Sidekiq's default — no auth until the user opts in).
    class Config
      # String forms that mean "off" — so `config.web.read_only = ENV[...]`
      # doesn't flip on when the env var is "0"/"false"/empty.
      FALSEY_STRINGS = ['', '0', 'false', 'no', 'off'].freeze

      # Firefox-profiler endpoints for the Profiles pane (spec §25.2). The
      # dashboard uploads a stored profile to `profile_store_url` and redirects
      # the operator to `profile_view_url % <returned-hash>`. Overridable for
      # self-hosted profiler instances.
      PROFILE_VIEW_URL  = 'https://profiler.firefox.com/public/%s'
      PROFILE_STORE_URL = 'https://api.profiler.firefox.com/compressed-store'

      # Sidekiq's built-in dashboard tabs (spec §25.3). The `tabs` hash starts
      # as a copy of this; extensions add to it via `register_extension` or by
      # mutating `tabs` directly — the same surface third-party gems use.
      DEFAULT_TABS = {
        'Dashboard' => '', 'Busy' => 'busy', 'Queues' => 'queues',
        'Retries' => 'retries', 'Scheduled' => 'scheduled', 'Dead' => 'morgue',
        'Metrics' => 'metrics', 'Profiles' => 'profiles'
      }.freeze

      # Tab paths the SPA already renders natively (Sidekiq DEFAULT_TABS plus
      # wurk's Pro/Ent extras). A gem re-registering one of these — e.g.
      # sidekiq-cron's "cron" — must not produce a duplicate nav item, so
      # `custom_tabs` filters them out.
      NATIVE_TAB_PATHS = %w[
        busy queues retries scheduled dead morgue metrics profiles
        batches limiters cron search
      ].freeze

      # Host-app Rack middleware stacked in front of the dashboard, newest
      # last. Each entry is `[middleware, args, block]`. Returns a frozen copy
      # so the memoized chain (`#rack_app`) can only be invalidated through
      # `#use` — direct mutation can't silently desync it.
      def middlewares
        @middlewares.dup.freeze
      end

      def initialize
        @authorization = nil
        @read_only = env_read_only?
        @read_only_message = nil
        @middlewares = []
        @rack_app = nil
        @profile_view_url = nil
        @profile_store_url = nil
        init_extensions!
      end

      # Firefox-profiler URLs, overridable; default to the public instance.
      attr_writer :profile_view_url, :profile_store_url

      def profile_view_url  = @profile_view_url || PROFILE_VIEW_URL
      def profile_store_url = @profile_store_url || PROFILE_STORE_URL

      # Optional banner copy shown by the dashboard in read-only mode. Nil →
      # the SPA falls back to its localized default ("Read-only mode"). Lets a
      # host explain *why* it's read-only — e.g. the public demo sets
      # "This is a public demo — actions are disabled."
      attr_accessor :read_only_message

      # Registers a `(env, method, path) -> truthy/falsey` block. Re-calling
      # overwrites; the spec exposes a single hook, not a chain.
      def authorization(&block)
        @authorization = block if block
        @authorization
      end

      # Web-extension surface (spec §25.2). Third-party gems (sidekiq-cron,
      # sidekiq-unique-jobs, sidekiq-status, …) register dashboard tabs at load
      # time. `tabs` is a mutable name→path hash seeded from DEFAULT_TABS;
      # `custom_job_info_rows` collects callables that add rows to the job
      # detail view; `app_url` / `assets_path` mirror Sidekiq's accessors.
      attr_reader :tabs, :extensions
      attr_accessor :custom_job_info_rows, :app_url, :assets_path

      # Matches Sidekiq::Web::Config#register_extension (aliased `register`).
      # Records the tab so it surfaces in the SPA nav via /api/meta. It does
      # NOT invoke the extension's server-side routes/views: wurk's dashboard
      # is a precompiled React SPA with no Sinatra/ERB render path, so an ext's
      # own view can't be injected (documented divergence — the registration is
      # accepted no-op-safe so requiring the gem never crashes boot). Returns
      # self so chained registrations read naturally.
      # rubocop:disable Metrics/ParameterLists -- signature matches Sidekiq::Web::Config#register_extension (spec §25.2)
      def register_extension(extension, name:, tab:, index: nil, root_dir: nil,
                             cache_for: 86_400, asset_paths: nil)
        @tabs[name] = tab
        @extensions << {
          extension: extension, name: name, tab: tab, index: index,
          root_dir: root_dir, cache_for: cache_for, asset_paths: asset_paths
        }
        self
      end
      # rubocop:enable Metrics/ParameterLists
      alias register register_extension

      # Tabs the SPA should render in the nav: everything registered beyond the
      # Sidekiq defaults and wurk's own native pages, as `{ name:, path: }`.
      def custom_tabs
        @tabs.filter_map do |name, path|
          next if DEFAULT_TABS.key?(name) || NATIVE_TAB_PATHS.include?(path.to_s)

          { name: name, path: path.to_s }
        end
      end

      # Evaluate the registered `custom_job_info_rows` against a job (spec
      # §25.2), returning `[[label, value], …]` for the SPA's job-detail modal.
      # Each row is a callable (`call(job)`) or a Sidekiq-style `add_pair(job)`
      # object; a row that raises or returns a non-pair is skipped so one bad
      # extension can't break the job views.
      def job_info_pairs(job)
        return [] if @custom_job_info_rows.empty?

        @custom_job_info_rows.filter_map { |row| job_info_pair(row, job) }
      end

      # Sidekiq-compatible (`Sidekiq::Web.use`). Registers a Rack middleware
      # that wraps the dashboard, in front of the authorization hook, so a
      # host app can gate the UI with Devise/Warden/Sorcery/Rack::Auth::Basic
      # without writing its own middleware. `args` and an optional block pass
      # straight through to the middleware's `new`. Call before the first
      # request (i.e. from an initializer) — the chain is built once.
      def use(middleware, *args, &block)
        @middlewares << [middleware, args, block]
        @rack_app = nil
      end

      # Builds (once) the host-middleware chain wrapping `inner` and memoizes
      # it on this Config. `reset_config!` swaps in a fresh Config, so each
      # test rebuilds cleanly; production builds exactly once at boot.
      def rack_app(inner)
        @rack_app ||= begin
          stack = @middlewares
          ::Rack::Builder.new do
            stack.each { |middleware, args, block| use(middleware, *args, &block) }
            run inner
          end.to_app
        end
      end

      # Read-only mode. When on, the Authorization middleware blocks every
      # non-GET request (retry/kill/requeue/delete/pause/resume/clear) with
      # 403, and the SPA hides destructive actions via the /api/meta flag.
      # Defaults from WURK_WEB_READ_ONLY=1 so a viewer-only deploy (e.g. the
      # public demo) needs no Ruby config.
      def read_only=(value)
        @read_only = value.is_a?(String) ? !FALSEY_STRINGS.include?(value.strip.downcase) : !!value
      end

      def read_only?
        @read_only
      end

      def reset!
        @authorization = nil
        @read_only = env_read_only?
        @read_only_message = nil
        @middlewares = []
        @rack_app = nil
        @profile_view_url = nil
        @profile_store_url = nil
        init_extensions!
      end

      # Returns true when no block is registered, otherwise the block's
      # truthiness. The `path` argument is the engine-relative path so a
      # consumer mounting under `/wurk` sees `/api/stats`, not the host's
      # absolute path — that matches Sidekiq's contract.
      def authorized?(env, method, path)
        return true if @authorization.nil?

        !!@authorization.call(env, method, path)
      end

      private

      def env_read_only?
        ENV['WURK_WEB_READ_ONLY'] == '1'
      end

      def init_extensions!
        @tabs = DEFAULT_TABS.dup
        @extensions = []
        @custom_job_info_rows = []
        @app_url = nil
        @assets_path = nil
      end

      def job_info_pair(row, job)
        pair = job_info_row_value(row, job)
        return unless pair.is_a?(::Array) && pair.size == 2

        [pair[0].to_s, pair[1].to_s]
      rescue ::StandardError
        nil
      end

      def job_info_row_value(row, job)
        return row.call(job) if row.respond_to?(:call)

        row.add_pair(job) if row.respond_to?(:add_pair)
      end
    end

    class << self
      def config
        @config ||= Config.new
      end

      def configure
        yield config
      end

      # Class-level shorthand for `config.use` — mirrors `Sidekiq::Web.use`.
      def use(...)
        config.use(...)
      end

      # Class-level extension surface — gems call these straight off
      # `Sidekiq::Web` (e.g. `Sidekiq::Web.register(Ext, name:, tab:)` or
      # `Sidekiq::Web.tabs["Locks"] = "locks"`), not only inside `configure`.
      def register(extension, **)
        config.register_extension(extension, **)
      end
      alias register_extension register

      def tabs
        config.tabs
      end

      def custom_job_info_rows
        config.custom_job_info_rows
      end

      def app_url
        config.app_url
      end

      def app_url=(value)
        config.app_url = value
      end

      def assets_path
        config.assets_path
      end

      def assets_path=(value)
        config.assets_path = value
      end

      # Test helper — exposed for parity with `Wurk::Limiter.reset_config!`.
      # Production callers should not need to drop the auth block at runtime.
      def reset_config!
        @config = nil
      end
    end

    # Rack middleware inserted into the engine. Resolves PATH_INFO + REQUEST_METHOD
    # from `env` and delegates to `Wurk::Web.config`. The engine's mount path
    # is stripped via `SCRIPT_NAME` so the callback sees engine-relative paths.
    class Authorization
      FORBIDDEN_BODY = 'Forbidden'
      READ_ONLY_BODY = 'Read-only mode'
      FORBIDDEN_HEADERS = { 'Content-Type' => 'text/plain' }.freeze
      # Methods allowed while read-only. Anything else is a mutation and 403s.
      SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

      def initialize(app)
        @app = app
      end

      def call(env)
        method = env['REQUEST_METHOD']
        path = env['PATH_INFO'].to_s
        config = Wurk::Web.config
        return forbidden(FORBIDDEN_BODY) unless config.authorized?(env, method, path)
        return forbidden(READ_ONLY_BODY) if config.read_only? && !SAFE_METHODS.include?(method)

        @app.call(env)
      end

      private

      def forbidden(body)
        [403, FORBIDDEN_HEADERS.dup, [body]]
      end
    end

    # Engine Rack middleware that applies the host-registered `Wurk::Web.use`
    # chain (Devise/Warden/Sorcery/Rack::Auth::Basic) in front of the
    # dashboard. Inserted ahead of `Authorization` so host auth runs first and
    # its `env` (e.g. `env['warden']`) is visible to the authorization hook.
    # The chain is built lazily on first request — after host initializers
    # have run — then memoized on the Config.
    class MiddlewareStack
      def initialize(app)
        @app = app
      end

      def call(env)
        Wurk::Web.config.rack_app(@app).call(env)
      end
    end
  end
end
