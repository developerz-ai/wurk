# frozen_string_literal: true

require 'forwardable'
require 'rack/builder'

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
      extend Forwardable

      # String forms that mean "off" — so `config.web.read_only = ENV[...]`
      # doesn't flip on when the env var is "0"/"false"/empty.
      FALSEY_STRINGS = ['', '0', 'false', 'no', 'off'].freeze

      # Firefox-profiler endpoints for the Profiles pane (spec §25.2). The
      # dashboard uploads a stored profile to `profile_store_url` and redirects
      # the operator to `profile_view_url % <returned-hash>`. Overridable for
      # self-hosted profiler instances.
      PROFILE_VIEW_URL  = 'https://profiler.firefox.com/public/%s'
      PROFILE_STORE_URL = 'https://api.profiler.firefox.com/compressed-store'

      # Hash-style settings, same surface as Sidekiq::Web::Config (#204):
      # gems and apps write `Sidekiq::Web.configure { |c| c[:csrf] = false }`.
      # Seeded like upstream's OPTIONS; unknown keys are stored verbatim so a
      # setting wurk doesn't consume still round-trips (e.g. :csrf — wurk's
      # extension POST guard is the Sec-Fetch-Site check in
      # ExtensionsController, spec §25.1, not a token).
      OPTIONS = {
        profile_view_url: PROFILE_VIEW_URL,
        profile_store_url: PROFILE_STORE_URL
      }.freeze

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
      # last. Each entry is `[middleware, args, block]`. The LIVE array, like
      # Sidekiq::Web::Config#middlewares — callers mutate it directly
      # (sidekiq-cron's tests do `c.middlewares.clear`), so `#rack_app`
      # detects drift instead of this returning a frozen copy.
      attr_reader :middlewares

      def initialize
        @options = OPTIONS.dup
        @authorization = nil
        @read_only = env_read_only?
        @read_only_message = nil
        @middlewares = []
        @rack_app = nil
        init_extensions!
      end

      def_delegators :@options, :[], :[]=, :fetch, :key?, :has_key?, :merge!, :dig

      # Firefox-profiler URLs — named views over the same @options keys the
      # bracket surface exposes, so `c[:profile_view_url] = …` and
      # `c.profile_view_url = …` can't drift apart.
      def profile_view_url  = @options[:profile_view_url]
      def profile_store_url = @options[:profile_store_url]

      def profile_view_url=(value)
        @options[:profile_view_url] = value
      end

      def profile_store_url=(value)
        @options[:profile_store_url] = value
      end

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
      # `locales` is the mutable locale-directory list extensions append to
      # (`Sidekiq::Web.configure.locales << dir`) — the Extension renderer's
      # `t()` reads en.yml from every listed dir. Wurk's own SPA i18n is
      # separate, so it starts empty.
      attr_reader :tabs, :extensions, :locales
      attr_accessor :custom_job_info_rows, :app_url, :assets_path

      # Matches Sidekiq::Web::Config#register_extension (aliased `register`,
      # spec §25.2): `tab` is the label(s), `index` the path(s), `name` the
      # asset namespace. `tab`/`index` are zipped into the `tabs` hash
      # (label => path) so the tab surfaces in the SPA nav via /api/meta, and
      # the extension's `registered(app)` routes/ERB views are served by
      # Wurk::Web::Extension::Renderer under `ext/:name/*` (#187) — the SPA's
      # Extension page embeds the rendered HTML. Yields self to an optional
      # block for further config, and returns self.
      # rubocop:disable Metrics/ParameterLists -- signature matches Sidekiq::Web::Config#register_extension (spec §25.2)
      def register_extension(extension, name:, tab:, index:, root_dir: nil,
                             cache_for: 86_400, asset_paths: nil)
        Array(tab).zip(Array(index)).each { |label, path| @tabs[label] = path if label }
        # Upstream registers root_dir/locales automatically; extensions
        # without a root_dir append their dir to `locales` themselves.
        @locales << ::File.join(root_dir, 'locales') if root_dir
        @extensions << {
          extension: extension, name: name, tab: tab, index: index,
          root_dir: root_dir, cache_for: cache_for, asset_paths: asset_paths
        }
        yield self if block_given?
        self
      end
      # rubocop:enable Metrics/ParameterLists
      alias register register_extension

      # Tabs the SPA should render in the nav: everything registered beyond the
      # Sidekiq defaults and wurk's own native pages, as `{ name:, path:,
      # ext_name: }`. `ext_name` ties the tab back to a registered extension so
      # the Extension page can fetch its server-rendered view from
      # `ext/:ext_name/*`; nil for tabs added by bare `tabs[]=` mutation (the
      # SPA falls back to the iframe embed for those).
      def custom_tabs
        @tabs.filter_map do |name, path|
          # Same trailing-slash normalization as extension_for_index, so a
          # native path registered as "cron/" doesn't duplicate the native tab.
          next if DEFAULT_TABS.key?(name) || NATIVE_TAB_PATHS.include?(path.to_s.delete_suffix('/'))

          { name: name, path: path.to_s, ext_name: extension_for_index(path)&.dig(:name)&.to_s }
        end
      end

      # The registered extension whose `index` covers `path` ("locks/" and
      # "locks" are the same index).
      def extension_for_index(path)
        norm = path.to_s.delete_suffix('/')
        @extensions.find { |e| Array(e[:index]).any? { |i| i.to_s.delete_suffix('/') == norm } }
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

      # Builds the host-middleware chain wrapping `inner`, memoized against
      # `[inner, middlewares]` — `middlewares` is the live array (upstream
      # surface), so direct mutation after the first request triggers a
      # rebuild instead of silently serving the stale chain. Keying on
      # `inner` too matters for the same reason: memoizing on the
      # middleware list alone pins whichever `inner` app the *first* caller
      # passed, forever — a second mount (e.g. per-test Rack app, or a
      # second engine mount) would silently get served the first one's app.
      # Production builds exactly once at boot; the per-request comparison
      # is an == over a handful of entries plus one object identity check.
      def rack_app(inner)
        return @rack_app if @rack_app && @rack_app_key == [inner, @middlewares]

        @rack_app_key = [inner, @middlewares.dup]
        stack = @middlewares
        @rack_app = ::Rack::Builder.new do
          stack.each { |middleware, args, block| use(middleware, *args, &block) }
          run inner
        end.to_app
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
        @options = OPTIONS.dup
        @authorization = nil
        @read_only = env_read_only?
        @read_only_message = nil
        @middlewares = []
        @rack_app = nil
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
        @locales = []
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

      # With a block: yields the config (the documented configure form).
      # Without: returns it — upstream's blockless-getter form, which gems
      # use as `Sidekiq::Web.configure.tabs` (#204).
      def configure
        block_given? ? yield(config) : config
      end

      # Class-level shorthand for `config.use` — mirrors `Sidekiq::Web.use`.
      def use(...)
        config.use(...)
      end

      # Class-level extension surface — gems call these straight off
      # `Sidekiq::Web` (e.g. `Sidekiq::Web.register(Ext, name:, tab:)` or
      # `Sidekiq::Web.tabs["Locks"] = "locks"`), not only inside `configure`.
      def register(extension, **, &)
        config.register_extension(extension, **, &)
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
