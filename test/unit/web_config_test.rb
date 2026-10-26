# frozen_string_literal: true

require_relative '../test_helper'

class WebConfigTest < Wurk::Test::UnitCase
  # Mutates `Wurk::Web.config` — single global, so cannot run in parallel
  # with other classes that touch the same singleton.

  def setup
    super
    @previous_theme_env = ENV.delete('WURK_WEB_DEFAULT_THEME')
    Wurk::Web.reset_config!
  end

  def teardown
    Wurk::Web.reset_config!
    ENV['WURK_WEB_DEFAULT_THEME'] = @previous_theme_env
    super
  end

  # #162: profiler URLs default to the public Firefox profiler, overridable.
  def test_profile_urls_default_and_override
    cfg = Wurk::Web.config

    assert_equal 'https://profiler.firefox.com/public/%s', cfg.profile_view_url
    assert_equal 'https://api.profiler.firefox.com/compressed-store', cfg.profile_store_url

    cfg.profile_view_url = 'https://prof.internal/%s'
    cfg.profile_store_url = 'https://prof.internal/store'

    assert_equal 'https://prof.internal/%s', cfg.profile_view_url
    assert_equal 'https://prof.internal/store', cfg.profile_store_url
  end

  # #162 CR: reset! must drop profiler URL overrides back to the defaults.
  def test_reset_clears_profile_url_overrides
    cfg = Wurk::Web.config
    cfg.profile_view_url = 'https://prof.internal/%s'
    cfg.reset!

    assert_equal 'https://profiler.firefox.com/public/%s', cfg.profile_view_url
    assert_equal 'https://api.profiler.firefox.com/compressed-store', cfg.profile_store_url
  end

  def test_default_authorized_returns_true_when_block_absent
    assert Wurk::Web.config.authorized?({}, 'GET', '/api/stats')
  end

  def test_configure_yields_config_object
    yielded = nil
    Wurk::Web.configure { |c| yielded = c }

    assert_kind_of Wurk::Web::Config, yielded
  end

  def test_authorization_block_receives_env_method_path
    seen = nil
    Wurk::Web.configure do |c|
      c.authorization do |env, method, path|
        seen = [env, method, path]
        true
      end
    end

    Wurk::Web.config.authorized?({ 'KEY' => 'V' }, 'POST', '/api/stats')

    assert_equal [{ 'KEY' => 'V' }, 'POST', '/api/stats'], seen
  end

  def test_authorization_block_truthy_passes
    Wurk::Web.configure { |c| c.authorization { |_, _, _| 'admin' } }

    assert Wurk::Web.config.authorized?({}, 'GET', '/api/stats')
  end

  def test_authorization_block_falsey_denies
    Wurk::Web.configure { |c| c.authorization { |_, _, _| nil } }

    refute Wurk::Web.config.authorized?({}, 'GET', '/api/stats')
  end

  def test_re_registration_overwrites_block
    Wurk::Web.configure { |c| c.authorization { |_, _, _| true } }
    Wurk::Web.configure { |c| c.authorization { |_, _, _| false } }

    refute Wurk::Web.config.authorized?({}, 'GET', '/api/stats')
  end

  class ResponseMiddleware
    attr_reader :args, :block

    def initialize(app, *args, &block)
      @app = app
      @args = args
      @block = block
      @label = args.join(':')
      @label = block.call(@label) if block
    end

    def call(env)
      status, headers, body = @app.call(env)
      [status, headers, [*body, @label]]
    end
  end

  # --- rack_app memoization -----------------------------------------------

  def test_rack_app_rebuilds_after_middleware_class_slot_edit
    cfg = Wurk::Web.config
    cfg.use(ResponseMiddleware)
    inner = ->(_env) { [200, {}, ['ok']] }
    triple = cfg.middlewares.first
    first = cfg.rack_app(inner)

    assert_equal ['ok', ''], first.call({}).last
    triple[0] = Wurk::Web::Authorization
    cfg.authorization { false }
    rebuilt = cfg.rack_app(inner)

    refute_same first, rebuilt
    assert_equal [403, { 'Content-Type' => 'text/plain' }, ['Forbidden']], rebuilt.call({})
    assert_same triple, cfg.middlewares.first
  end

  def test_rack_app_rebuilds_after_middleware_args_slot_edit
    cfg = Wurk::Web.config
    cfg.use(ResponseMiddleware, 'before')
    inner = ->(_env) { [200, {}, ['ok']] }
    triple = cfg.middlewares.first
    first = cfg.rack_app(inner)

    assert_equal %w[ok before], first.call({}).last
    triple[1] = ['after']
    rebuilt = cfg.rack_app(inner)

    refute_same first, rebuilt
    assert_equal %w[ok after], rebuilt.call({}).last
    assert_same triple, cfg.middlewares.first
  end

  def test_rack_app_rebuilds_after_middleware_block_slot_edit
    cfg = Wurk::Web.config
    cfg.use(ResponseMiddleware, 'label') { |label| "before #{label}" }
    inner = ->(_env) { [200, {}, ['ok']] }
    triple = cfg.middlewares.first
    first = cfg.rack_app(inner)

    assert_equal ['ok', 'before label'], first.call({}).last
    triple[2] = ->(label) { "after #{label}" }
    rebuilt = cfg.rack_app(inner)

    refute_same first, rebuilt
    assert_equal ['ok', 'after label'], rebuilt.call({}).last
    assert_same triple[2], rebuilt.block
    assert_same triple, cfg.middlewares.first
  end

  def test_rack_app_rebuilds_each_inner_after_args_list_edits
    cfg = Wurk::Web.config
    cfg.use(ResponseMiddleware, 'before')
    inners = %w[engine standalone].map { |name| ->(_env) { [200, {}, [name]] } }
    apps = inners.map { |inner| cfg.rack_app(inner) }
    args = cfg.middlewares.first[1]
    edits = [-> { args[0] = 'after' }, -> { args << 'extra' }, -> { args.clear }]
    labels = ['after', 'after:extra', '']

    assert_equal %w[engine before], apps[0].call({}).last
    assert_equal %w[standalone before], apps[1].call({}).last
    edits.zip(labels).each do |edit, label|
      edit.call
      rebuilt = inners.map { |inner| cfg.rack_app(inner) }
      rebuilt.each_with_index do |app, index|
        refute_same apps[index], app
        assert_equal [index.zero? ? 'engine' : 'standalone', label], app.call({}).last
        assert_same app, cfg.rack_app(inners[index])
      end
      assert_same args, cfg.middlewares.first[1]
      apps = rebuilt
    end
  end

  def test_rack_app_rebuilds_after_outer_array_replacement_and_clear
    cfg = Wurk::Web.config
    cfg.use(ResponseMiddleware, 'before')
    middlewares = cfg.middlewares
    inner = ->(_env) { [200, {}, ['ok']] }
    first = cfg.rack_app(inner)

    assert_equal %w[ok before], first.call({}).last
    middlewares.replace([[ResponseMiddleware, ['after'], nil]])
    replaced = cfg.rack_app(inner)

    refute_same first, replaced
    assert_equal %w[ok after], replaced.call({}).last
    assert_same replaced, cfg.rack_app(inner)
    middlewares.clear
    cleared = cfg.rack_app(inner)

    refute_same replaced, cleared
    assert_equal ['ok'], cleared.call({}).last
    assert_same cleared, cfg.rack_app(inner)
    assert_same middlewares, cfg.middlewares
  end

  def test_rack_app_reuses_chain_after_equal_configuration_replacement
    cfg = Wurk::Web.config
    block = ->(label) { "cached #{label}" }
    cfg.use(ResponseMiddleware, 'label', &block)
    inner = ->(_env) { [200, {}, ['ok']] }
    first = cfg.rack_app(inner)
    triple = cfg.middlewares.first
    replacement = [ResponseMiddleware, [String.new('label')], block]
    cfg.middlewares[0] = replacement

    refute_same triple, replacement
    refute_same triple[1], replacement[1]
    assert_equal triple, replacement
    assert_same first, cfg.rack_app(inner)
    assert_equal ['ok', 'cached label'], cfg.rack_app(inner).call({}).last
  end

  def test_rack_app_preserves_argument_and_block_identities
    cfg = Wurk::Web.config
    argument = Object.new
    block = ->(_label) { 'label' }
    cfg.use(ResponseMiddleware, argument, &block)
    inner = ->(_env) { [200, {}, ['ok']] }
    app = cfg.rack_app(inner)

    assert_same argument, app.args.first
    assert_same block, app.block
    assert_same app, cfg.rack_app(inner)
    assert_equal %w[ok label], app.call({}).last
  end

  def test_rack_app_caches_for_the_same_inner_and_middlewares
    inner = ->(_env) { [200, {}, ['ok']] }

    first = Wurk::Web.config.rack_app(inner)
    second = Wurk::Web.config.rack_app(inner)

    assert_same first, second
    assert_equal ['ok'], second.call({}).last
  end

  def test_rack_app_rebuilds_when_middlewares_change
    inner = ->(_env) { [200, {}, ['ok']] }
    first = Wurk::Web.config.rack_app(inner)
    Wurk::Web.configure { |c| c.use(ResponseMiddleware, 'added') }
    second = Wurk::Web.config.rack_app(inner)

    refute_same first, second
    assert_equal ['ok'], first.call({}).last
    assert_equal %w[ok added], second.call({}).last
  end

  # Regression: memoizing on the middleware list alone pins whichever
  # `inner` the *first* caller passed, forever — a second mount (a second
  # test's Rack app, a second engine mount) would silently get served the
  # first one's app instead of its own.
  def test_rack_app_rebuilds_when_inner_changes
    first_inner = ->(_env) { [200, {}, ['first']] }
    second_inner = ->(_env) { [200, {}, ['second']] }

    first_app = Wurk::Web.config.rack_app(first_inner)
    second_app = Wurk::Web.config.rack_app(second_inner)

    refute_same first_app, second_app
    _status, _headers, body = second_app.call(rack_env('GET', '/'))

    assert_equal ['second'], body
  end

  # The engine's MiddlewareStack and the standalone `Sidekiq::Web.call` each
  # pass their own inner app; with one cache slot every alternating request
  # rebuilt the other's chain.
  def test_rack_app_caches_each_inner_side_by_side
    Wurk::Web.config.use(ResponseMiddleware, 'cached')
    engine_inner = ->(_env) { [200, {}, ['engine']] }
    standalone_inner = ->(_env) { [200, {}, ['standalone']] }

    engine_app = Wurk::Web.config.rack_app(engine_inner)
    standalone_app = Wurk::Web.config.rack_app(standalone_inner)

    assert_same engine_app, Wurk::Web.config.rack_app(engine_inner)
    assert_same standalone_app, Wurk::Web.config.rack_app(standalone_inner)
    assert_equal %w[engine cached], engine_app.call({}).last
    assert_equal %w[standalone cached], standalone_app.call({}).last
  end

  # --- Rack middleware --------------------------------------------------

  def test_middleware_returns_200_when_authorized
    app = ->(_env) { [200, {}, ['ok']] }
    mw = Wurk::Web::Authorization.new(app)

    status, _headers, body = mw.call(rack_env('GET', '/api/stats'))

    assert_equal 200, status
    assert_equal ['ok'], body
  end

  def test_middleware_returns_403_when_block_denies
    Wurk::Web.configure { |c| c.authorization { |_, _, _| false } }
    app = ->(_env) { [200, {}, ['should not run']] }
    mw = Wurk::Web::Authorization.new(app)

    status, headers, body = mw.call(rack_env('GET', '/api/stats'))

    assert_equal 403, status
    assert_equal 'text/plain', headers['Content-Type']
    assert_equal ['Forbidden'], body
  end

  def test_middleware_passes_method_and_path_to_block
    captured = nil
    Wurk::Web.configure do |c|
      c.authorization do |_, method, path|
        captured = [method, path]
        true
      end
    end
    mw = Wurk::Web::Authorization.new(->(_env) { [200, {}, []] })

    mw.call(rack_env('DELETE', '/api/dead/123'))

    assert_equal %w[DELETE /api/dead/123], captured
  end

  # --- Read-only mode ---------------------------------------------------

  def test_read_only_defaults_off
    refute_predicate Wurk::Web.config, :read_only?
  end

  def test_read_only_message_defaults_nil
    assert_nil Wurk::Web.config.read_only_message
  end

  def test_read_only_message_is_configurable
    Wurk::Web.configure { |c| c.read_only_message = 'public demo — actions disabled' }

    assert_equal 'public demo — actions disabled', Wurk::Web.config.read_only_message
  end

  def test_reset_clears_read_only_message
    Wurk::Web.configure { |c| c.read_only_message = 'x' }
    Wurk::Web.reset_config!

    assert_nil Wurk::Web.config.read_only_message
  end

  def test_read_only_writer_coerces_to_boolean
    Wurk::Web.configure { |c| c.read_only = 'yes' }

    assert_predicate Wurk::Web.config, :read_only?
  end

  def test_read_only_writer_treats_falsey_strings_as_off
    ['0', 'false', 'FALSE', 'no', 'off', ' ', ''].each do |off|
      Wurk::Web.configure { |c| c.read_only = off }

      refute_predicate Wurk::Web.config, :read_only?, "expected #{off.inspect} to be off"
    end
  end

  def test_read_only_defaults_from_env
    with_env('WURK_WEB_READ_ONLY', '1') do
      Wurk::Web.reset_config!

      assert_predicate Wurk::Web.config, :read_only?
    end
  end

  def test_read_only_blocks_mutating_request
    Wurk::Web.configure { |c| c.read_only = true }
    app = ->(_env) { [200, {}, ['should not run']] }
    mw = Wurk::Web::Authorization.new(app)

    status, headers, body = mw.call(rack_env('POST', '/api/cron/x/pause'))

    assert_equal 403, status
    assert_equal 'text/plain', headers['Content-Type']
    assert_equal ['Read-only mode'], body
  end

  def test_read_only_allows_get_request
    Wurk::Web.configure { |c| c.read_only = true }
    mw = Wurk::Web::Authorization.new(->(_env) { [200, {}, ['ok']] })

    status, _headers, body = mw.call(rack_env('GET', '/api/stats'))

    assert_equal 200, status
    assert_equal ['ok'], body
  end

  def test_authorization_block_runs_before_read_only_check
    Wurk::Web.configure do |c|
      c.authorization { |_, _, _| false }
      c.read_only = true
    end
    mw = Wurk::Web::Authorization.new(->(_env) { [200, {}, []] })

    _status, _headers, body = mw.call(rack_env('GET', '/api/stats'))

    assert_equal ['Forbidden'], body
  end

  # --- web extensions / custom tabs (spec §25.2/§25.3) ---------------

  def test_tabs_seed_from_default_tabs_as_a_mutable_copy
    assert_equal Wurk::Web::Config::DEFAULT_TABS, Wurk::Web.config.tabs
    refute_same Wurk::Web::Config::DEFAULT_TABS, Wurk::Web.config.tabs
  end

  # tab = label, index = path, name = asset namespace (spec §25.2).
  def test_register_extension_adds_a_custom_tab
    Wurk::Web.config.register_extension(Object, name: 'locks', tab: 'Locks', index: 'locks')

    assert_equal 'locks', Wurk::Web.config.tabs['Locks']
    assert_includes Wurk::Web.config.custom_tabs, { name: 'Locks', path: 'locks', ext_name: 'locks' }
  end

  def test_register_is_an_alias_for_register_extension
    Wurk::Web.config.register(Object, name: 'status', tab: 'Status', index: 'status')

    assert_includes Wurk::Web.config.custom_tabs, { name: 'Status', path: 'status', ext_name: 'status' }
  end

  def test_register_extension_returns_self_for_chaining
    cfg = Wurk::Web.config

    assert_same cfg, cfg.register_extension(Object, name: 'a', tab: 'A', index: 'a')
  end

  def test_register_extension_yields_config_to_block
    cfg = Wurk::Web.config
    yielded = nil
    cfg.register_extension(Object, name: 'locks', tab: 'Locks', index: 'locks') { |c| yielded = c }

    assert_same cfg, yielded
  end

  # tab/index may be arrays — zipped label => path (spec §25.2).
  def test_register_extension_zips_array_tabs_and_indexes
    Wurk::Web.config.register_extension(Object, name: 'uj', tab: %w[Locks Expiry], index: %w[locks expiry])
    paths = Wurk::Web.config.custom_tabs.map { |t| t[:path] }

    assert_equal %w[locks expiry], paths
  end

  def test_custom_tabs_excludes_native_and_default_paths
    cfg = Wurk::Web.config
    cfg.register_extension(Object, name: 'cron', tab: 'Cron', index: 'cron')         # wurk-native path
    cfg.register_extension(Object, name: 'queues', tab: 'Queues', index: 'queues')   # Sidekiq default
    cfg.register_extension(Object, name: 'locks', tab: 'Locks', index: 'locks')      # genuinely new
    paths = cfg.custom_tabs.map { |t| t[:path] }

    assert_equal ['locks'], paths
  end

  def test_tabs_hash_is_directly_mutable
    Wurk::Web.config.tabs['Expiry'] = 'expiry'

    # Bare tabs[]= mutation registers no extension, so there's nothing to render (ext_name nil).
    assert_includes Wurk::Web.config.custom_tabs, { name: 'Expiry', path: 'expiry', ext_name: nil }
  end

  def test_custom_job_info_rows_is_a_mutable_array
    assert_empty Wurk::Web.config.custom_job_info_rows
    row = ->(job) { ['Custom', job] }
    Wurk::Web.config.custom_job_info_rows << row

    assert_equal [row], Wurk::Web.config.custom_job_info_rows
  end

  def test_app_url_and_assets_path_accessors
    cfg = Wurk::Web.config
    cfg.app_url = 'https://app.example'
    cfg.assets_path = '/assets'

    assert_equal 'https://app.example', cfg.app_url
    assert_equal '/assets', cfg.assets_path
  end

  def test_reset_clears_registered_extensions
    cfg = Wurk::Web.config
    cfg.register_extension(Object, name: 'locks', tab: 'Locks', index: 'locks')
    cfg.custom_job_info_rows << :row
    cfg.app_url = 'https://app.example'
    cfg.reset!

    assert_empty cfg.custom_tabs
    assert_empty cfg.custom_job_info_rows
    assert_nil cfg.app_url
  end

  # No-op-safe: registering must only record the class, never invoke the
  # extension's server-side routes/views (wurk has no Sinatra render path).
  def test_register_records_extension_without_invoking_it
    ext = Class.new do
      def self.registered(*)
        raise 'extension code must not run at register time'
      end
    end
    Wurk::Web.config.register_extension(ext, name: 'safe', tab: 'Safe', index: 'safe')
    last = Wurk::Web.config.extensions.last

    assert_equal ext, last[:extension]
    assert_equal 86_400, last[:cache_for]
  end

  # Drop-in: gems reach this surface through the Sidekiq::Web alias.
  def test_sidekiq_web_class_level_surface
    assert_same Wurk::Web::Config, Sidekiq::Web::Config
    Sidekiq::Web.register(Object, name: 'locks', tab: 'Locks', index: 'locks')
    Sidekiq::Web.tabs['Expiry'] = 'expiry'

    paths = Sidekiq::Web.config.custom_tabs.map { |t| t[:path] }

    assert_includes paths, 'locks'
    assert_includes paths, 'expiry'
  end

  # Gems call these straight off `Sidekiq::Web` at boot (upstream class
  # methods); they must be the live config collections, not copies.
  def test_sidekiq_web_locales_views_middlewares_delegate_to_config
    cfg = Wurk::Web.config

    assert_same cfg.locales, Sidekiq::Web.locales
    assert_same cfg.middlewares, Sidekiq::Web.middlewares
    assert_same cfg.views, Sidekiq::Web.views
    Sidekiq::Web.views << '/gem/views'

    assert_equal ['/gem/views'], cfg.views
  end

  def test_reset_clears_views
    Wurk::Web.views << '/gem/views'
    Wurk::Web.reset_config!

    assert_empty Wurk::Web.views
  end

  def test_max_streams_defaults_to_nil_so_the_cap_is_derived
    assert_nil Wurk::Web.config.max_streams
  end

  def test_max_streams_accepts_nil_zero_and_positive_integers
    cfg = Wurk::Web.config
    cfg.max_streams = 4

    assert_equal 4, cfg.max_streams
    cfg.max_streams = 0

    assert_equal 0, cfg.max_streams
    cfg.max_streams = nil

    assert_nil cfg.max_streams
  end

  def test_max_streams_rejects_negative_and_non_integer_values
    [-1, '4', 2.5, true].each do |value|
      assert_raises(ArgumentError, value.inspect) { Wurk::Web.config.max_streams = value }
    end
  end

  def test_reset_clears_max_streams
    Wurk::Web.config.max_streams = 2
    Wurk::Web.reset_config!

    assert_nil Wurk::Web.config.max_streams
  end

  def test_locale_settings_default_to_the_shipped_bundles
    cfg = Wurk::Web.config

    assert_equal Wurk::Web::Config::BUNDLED_LOCALES, cfg.offered_locales
    assert_nil cfg.default_locale
    assert_empty cfg.translations
  end

  def test_locale_settings_are_configurable
    Wurk::Web.configure do |c|
      c.offered_locales = %w[en de he]
      c.default_locale = 'de'
      c.translations = { 'en' => { 'nav' => { 'queues' => 'Pipelines' } } }
    end
    cfg = Wurk::Web.config

    assert_equal %w[en de he], cfg.offered_locales
    assert_equal 'de', cfg.default_locale
    assert_equal 'Pipelines', cfg.translations.dig('en', 'nav', 'queues')
  end

  def test_translations_accept_nested_strings_and_empty_hashes_without_changing_keys
    cfg = Wurk::Web.config
    translations = {
      'en' => { 'nav' => { 'queues' => 'Pipelines', 'empty' => '' }, 'unused' => {} },
      fr: { nav: { queues: 'Files' } },
      'de' => {}
    }
    cfg.translations = translations

    assert_same translations, cfg.translations
    assert_equal 'Pipelines', cfg.translations.dig('en', 'nav', 'queues')
    assert_empty cfg.translations.dig('en', 'nav', 'empty')
    assert_equal 'Files', cfg.translations.dig(:fr, :nav, :queues)
    assert_empty cfg.translations.dig('en', 'unused')
    assert_empty cfg.translations['de']

    cfg.translations = {}

    assert_empty cfg.translations
  end

  def test_translations_reject_non_string_leaves_without_replacing_previous_copy
    cfg = Wurk::Web.config
    previous = { 'en' => { 'nav' => { 'queues' => 'Original' } } }
    cfg.translations = previous

    [42, 1.5, true, false, nil, [], ['text'], :text].each do |leaf|
      invalid = {
        'en' => { 'nav' => { 'queues' => 'Replacement' } },
        'fr' => { 'nav' => { 'queues' => leaf } }
      }
      error = assert_raises(ArgumentError, leaf.inspect) { cfg.translations = invalid }

      assert_includes error.message, 'translations["fr"]["nav"]["queues"]'
      assert_includes error.message, 'String or Hash'
      assert_includes error.message, leaf.class.to_s
      assert_same previous, cfg.translations
      assert_equal({ 'en' => { 'nav' => { 'queues' => 'Original' } } }, cfg.translations)
    end
  end

  def test_translations_reject_malformed_root_and_locale_containers
    cfg = Wurk::Web.config
    previous = { 'en' => { 'nav' => { 'queues' => 'Original' } } }
    cfg.translations = previous

    [nil, [], 'text', 42, true, false, :text].each do |value|
      error = assert_raises(ArgumentError, value.inspect) { cfg.translations = value }

      assert_includes error.message, 'translations must be a Hash'
      assert_includes error.message, value.class.to_s
      assert_same previous, cfg.translations

      error = assert_raises(ArgumentError, value.inspect) do
        cfg.translations = { 'en' => {}, fr: value }
      end

      assert_includes error.message, 'translations[:fr] must be a Hash'
      assert_includes error.message, value.class.to_s
      assert_same previous, cfg.translations
      assert_equal({ 'en' => { 'nav' => { 'queues' => 'Original' } } }, cfg.translations)
    end
  end

  def test_reset_clears_locale_settings
    cfg = Wurk::Web.config
    cfg.offered_locales = %w[fr]
    cfg.default_locale = 'fr'
    cfg.translations = { 'fr' => {} }
    cfg.reset!

    assert_equal Wurk::Web::Config::BUNDLED_LOCALES, cfg.offered_locales
    assert_nil cfg.default_locale
    assert_empty cfg.translations
  end

  def test_default_theme_starts_unset_so_the_spa_follows_the_visitor
    assert_nil Wurk::Web.config.default_theme
  end

  def test_default_theme_seeds_from_env_without_server_configuration
    %w[light dark system].each do |theme|
      with_env('WURK_WEB_DEFAULT_THEME', theme) do
        Wurk::Web.reset_config!

        assert_equal theme, Wurk::Web.config.default_theme
      end
    end
  end

  def test_default_theme_env_rejects_unsupported_strings
    ['', 'Dark', 'DARK', ' dark', 'dark ', ' ', 'obsidian'].each do |theme|
      with_env('WURK_WEB_DEFAULT_THEME', theme) do
        Wurk::Web.reset_config!
        error = assert_raises(ArgumentError, theme.inspect) { Wurk::Web.config }

        assert_match(/default_theme/, error.message)
        assert_includes error.message, theme.inspect
      end
    end
  end

  def test_explicit_default_theme_overrides_env_and_nil_clears_it
    with_env('WURK_WEB_DEFAULT_THEME', 'dark') do
      cfg = Wurk::Web.config

      assert_equal 'dark', cfg.default_theme

      cfg.default_theme = 'light'

      assert_equal 'light', cfg.default_theme

      cfg.default_theme = nil

      assert_nil cfg.default_theme
    end
  end

  def test_reset_samples_the_theme_env_again
    with_env('WURK_WEB_DEFAULT_THEME', 'dark') do
      cfg = Wurk::Web.config
      cfg.default_theme = 'light'
      with_env('WURK_WEB_DEFAULT_THEME', 'system') do
        assert_equal 'light', cfg.default_theme

        cfg.reset!

        assert_equal 'system', cfg.default_theme
      end

      cfg.reset!

      assert_equal 'dark', cfg.default_theme

      with_env('WURK_WEB_DEFAULT_THEME', nil) do
        cfg.reset!

        assert_nil cfg.default_theme
      end
    end
  end

  def test_default_theme_accepts_every_preference_the_spa_resolves
    cfg = Wurk::Web.config

    Wurk::Web::Config::THEMES.each do |theme|
      cfg.default_theme = theme

      assert_equal theme, cfg.default_theme
    end

    cfg.default_theme = :light

    assert_equal 'light', cfg.default_theme
  end

  # Loud rather than ignored: a typo'd theme that silently does nothing is a
  # support ticket, and there are only three values to get right.
  def test_default_theme_rejects_a_preference_the_spa_cannot_resolve
    error = assert_raises(ArgumentError) { Wurk::Web.config.default_theme = 'obsidian' }

    assert_match(/default_theme/, error.message)
  end

  def test_default_theme_can_be_cleared
    cfg = Wurk::Web.config
    cfg.default_theme = 'dark'
    cfg.default_theme = nil

    assert_nil cfg.default_theme
  end

  def test_reset_clears_the_default_theme
    cfg = Wurk::Web.config
    cfg.default_theme = 'light'
    cfg.reset!

    assert_nil cfg.default_theme
  end

  # The server negotiates Accept-Language against BUNDLED_LOCALES, but the SPA
  # decides what it can actually render from its own bundle imports. A bundle
  # added on one side only would emit a hint the dashboard can't honour, so pin
  # the two lists together at the source of truth: the JSON files themselves.
  def test_bundled_locales_match_the_shipped_translation_files
    dir = File.expand_path('../../frontend/src/i18n', __dir__)
    skip 'frontend sources absent (installed gem)' unless File.directory?(dir)

    shipped = Dir.children(dir).grep(/\.json\z/).map { |f| File.basename(f, '.json') }

    assert_equal shipped.sort, Wurk::Web::Config::BUNDLED_LOCALES.sort
  end

  # The shell's pre-paint script (frontend/index.html) hand-duplicates the SPA's
  # preference resolution — it has to run before the bundle exists, or every
  # dark-mode visitor gets a white flash. Pin its accepted values to the ones
  # this config will emit, so a theme added on one side alone fails here rather
  # than silently resolving to 'system' in front of first paint.
  def test_themes_match_the_shells_pre_paint_script
    shell = File.expand_path('../../frontend/index.html', __dir__)
    skip 'frontend sources absent (installed gem)' unless File.exist?(shell)

    accepted = File.read(shell).scan(/v === '([a-z]+)'/).flatten

    assert_equal Wurk::Web::Config::THEMES.sort, accepted.sort
  end

  private

  def with_env(key, value)
    previous = ENV.fetch(key, nil)
    ENV[key] = value
    yield
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
  end

  def rack_env(method, path)
    { 'REQUEST_METHOD' => method, 'PATH_INFO' => path }
  end
end
