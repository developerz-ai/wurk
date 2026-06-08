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
