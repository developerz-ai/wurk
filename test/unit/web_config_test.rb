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

  private

  def rack_env(method, path)
    { 'REQUEST_METHOD' => method, 'PATH_INFO' => path }
  end
end
