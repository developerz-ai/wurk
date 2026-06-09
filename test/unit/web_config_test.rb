# frozen_string_literal: true

require_relative '../test_helper'

class WebConfigTest < Wurk::Test::UnitCase
  # Mutates `Wurk::Web.config` — single global, so cannot run in parallel
  # with other classes that touch the same singleton.

  def setup
    super
    Wurk::Web.reset_config!
  end

  def teardown
    Wurk::Web.reset_config!
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
    refute Wurk::Web.config.read_only?
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

    assert_equal true, Wurk::Web.config.read_only?
  end

  def test_read_only_writer_treats_falsey_strings_as_off
    ['0', 'false', 'FALSE', 'no', 'off', ' ', ''].each do |off|
      Wurk::Web.configure { |c| c.read_only = off }

      assert_equal false, Wurk::Web.config.read_only?, "expected #{off.inspect} to be off"
    end
  end

  def test_read_only_defaults_from_env
    with_env('WURK_WEB_READ_ONLY', '1') do
      Wurk::Web.reset_config!

      assert Wurk::Web.config.read_only?
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
    assert_includes Wurk::Web.config.custom_tabs, { name: 'Locks', path: 'locks' }
  end

  def test_register_is_an_alias_for_register_extension
    Wurk::Web.config.register(Object, name: 'status', tab: 'Status', index: 'status')

    assert_includes Wurk::Web.config.custom_tabs, { name: 'Status', path: 'status' }
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

    assert_includes Wurk::Web.config.custom_tabs, { name: 'Expiry', path: 'expiry' }
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

  private

  def with_env(key, value)
    previous = ENV[key]
    ENV[key] = value
    yield
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
  end

  def rack_env(method, path)
    { 'REQUEST_METHOD' => method, 'PATH_INFO' => path }
  end
end
