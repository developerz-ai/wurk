# frozen_string_literal: true

require_relative '../test_helper'
require 'rack'
require 'tmpdir'
require 'fileutils'
require 'wurk/web/extension'

# #204: `Sidekiq::Web` as an upstream-compatible standalone Rack app —
# `run Sidekiq::Web` / rack-test `Sidekiq::Web.call(env)` serves registered
# extension routes at their own paths (no engine), with upstream's
# Sec-Fetch-Site CSRF model and Config's hash-style settings.
class WebRackAppTest < Wurk::Test::UnitCase
  # Mutates the process-global Wurk::Web.config singleton (middlewares,
  # bracket options) — cannot run in parallel with classes touching it.

  module StandaloneExt
    def self.registered(app)
      app.get '/standalone' do
        "standalone body #{t('Greeting')}"
      end

      app.get '/standalone/jump' do
        redirect "#{root_path}standalone"
      end

      app.post '/standalone/poke' do
        redirect "#{root_path}standalone"
      end
    end
  end

  module ApiShapedExt
    def self.registered(app)
      app.post '/api/v1/thing' do
        'mutated'
      end
    end
  end

  class WardenStub
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env.merge('warden.user' => 'admin'))
    end
  end

  # Tags responses so tests can prove the host middleware chain ran.
  class StampMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      [status, headers.merge('X-Stamp' => '1'), body]
    end
  end

  def setup
    super
    Wurk::Web.reset_config!
    Wurk::Web.register(StandaloneExt, name: 'standalone', tab: 'Standalone', index: 'standalone')
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def test_get_serves_extension_route_at_its_own_path
    status, _headers, body = Wurk::Web.call(env_for('GET', '/standalone'))

    assert_equal 200, status
    assert_includes body.join, 'standalone body'
  end

  def test_redirect_location_stays_in_the_root_url_space
    status, headers, = Wurk::Web.call(env_for('GET', '/standalone/jump'))

    assert_equal 302, status
    assert_equal '/standalone', headers['Location'], 'standalone redirects must not be rewritten to /ext/…'
  end

  def test_unsafe_method_without_same_origin_header_is_denied
    status, _headers, body = Wurk::Web.call(env_for('POST', '/standalone/poke'))

    assert_equal 403, status
    assert_includes body.join, 'Forbidden'
  end

  def test_unsafe_method_with_same_origin_header_routes
    env = env_for('POST', '/standalone/poke').merge('HTTP_SEC_FETCH_SITE' => 'same-origin')
    status, headers, = Wurk::Web.call(env)

    assert_equal 302, status
    assert_equal '/standalone', headers['Location']
  end

  def test_unknown_path_is_404
    status, _headers, body = Wurk::Web.call(env_for('GET', '/nope'))

    assert_equal 404, status
    refute_empty body.join
  end

  # --- W1: the standalone mount runs the same gates as the engine ---------

  def test_authorization_denial_is_403_on_get_through_sidekiq_web
    Sidekiq::Web.configure { |c| c.authorization { |_env, _method, _path| false } }

    status, _headers, body = Sidekiq::Web.call(env_for('GET', '/standalone'))

    assert_equal 403, status
    assert_equal 'Forbidden', body.join
  end

  # A forged Sec-Fetch-Site passes the CSRF check (curl can set any header);
  # it must not pass authorization.
  def test_authorization_denial_is_403_on_forged_same_origin_post
    Sidekiq::Web.configure { |c| c.authorization { |_env, _method, _path| false } }
    env = env_for('POST', '/standalone/poke').merge('HTTP_SEC_FETCH_SITE' => 'same-origin')

    status, _headers, body = Sidekiq::Web.call(env)

    assert_equal 403, status
    assert_equal 'Forbidden', body.join
  end

  def test_authorization_sees_method_and_mount_relative_path
    seen = nil
    Sidekiq::Web.configure { |c| c.authorization { |_env, method, path| seen = [method, path] } }

    Sidekiq::Web.call(env_for('GET', '/standalone').merge('SCRIPT_NAME' => '/sidekiq'))

    assert_equal ['GET', '/standalone'], seen
  end

  def test_read_only_refuses_post_and_still_serves_get
    Sidekiq::Web.configure { |c| c.read_only = true }
    env = env_for('POST', '/standalone/poke').merge('HTTP_SEC_FETCH_SITE' => 'same-origin')

    status, _headers, body = Sidekiq::Web.call(env)

    assert_equal 403, status
    assert_equal 'Read-only mode', body.join
    assert_equal 200, Sidekiq::Web.call(env_for('GET', '/standalone'))[0]
  end

  # The machine API never lives under this mount, so an /api/v1 path is just
  # an extension path — read-only must not hand it off and wave it through.
  def test_read_only_refuses_api_shaped_extension_path
    Wurk::Web.register(ApiShapedExt, name: 'apishaped', tab: 'ApiShaped', index: 'api/v1/thing')
    Sidekiq::Web.configure { |c| c.read_only = true }
    env = env_for('POST', '/api/v1/thing').merge('HTTP_SEC_FETCH_SITE' => 'same-origin')

    token = 'standalone-gate-token-0123456789abcdef'
    Wurk.configuration.api_token(token, scopes: %i[admin])

    assert_equal 403, Sidekiq::Web.call(env)[0]
  ensure
    Wurk.configuration.api_tokens.delete(token)
  end

  # Host middleware runs outside the gate, so its env (e.g. warden) reaches
  # the authorization hook, as on the engine mount.
  def test_host_middleware_runs_before_authorization
    Sidekiq::Web.use(WardenStub)
    Sidekiq::Web.configure { |c| c.authorization { |env, _method, _path| env['warden.user'] == 'admin' } }

    assert_equal 200, Sidekiq::Web.call(env_for('GET', '/standalone'))[0]
  end

  # `middlewares` is the live array (upstream surface): mutating it after the
  # first request must rebuild the chain, not serve the stale memo.
  def test_live_middleware_mutation_rebuilds_the_chain
    _, headers, = Wurk::Web.call(env_for('GET', '/standalone'))

    assert_nil headers['X-Stamp']

    Wurk::Web.use(StampMiddleware)
    _, headers, = Wurk::Web.call(env_for('GET', '/standalone'))

    assert_equal '1', headers['X-Stamp']

    Wurk::Web.config.middlewares.clear
    _, headers, = Wurk::Web.call(env_for('GET', '/standalone'))

    assert_nil headers['X-Stamp'], 'clearing the live array must drop the middleware'
  end

  def test_config_bracket_settings_round_trip
    Wurk::Web.configure { |c| c[:csrf] = false }
    cfg = Wurk::Web.config

    # key? + refute together pin "stored as false", not merely absent.
    assert cfg.key?(:csrf)
    refute cfg.fetch(:csrf)
    assert_equal 'https://profiler.firefox.com/public/%s', cfg[:profile_view_url],
                 'bracket surface and named accessors share the options hash'
  end

  def test_configure_without_block_returns_the_config
    assert_same Wurk::Web.config, Wurk::Web.configure
  end

  # The upstream extension protocol sidekiq-cron uses: append a locale dir to
  # `configure.locales`; the renderer's t() resolves strings from it.
  def test_extension_locales_feed_renderer_strings
    dir = Dir.mktmpdir
    File.write(File.join(dir, 'en.yml'), "en:\n  Greeting: hi-from-locale\n")
    Wurk::Web.configure.locales << dir

    _, _, body = Wurk::Web.call(env_for('GET', '/standalone'))

    assert_includes body.join, 'hi-from-locale'
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  private

  def env_for(method, path)
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => '',
      'QUERY_STRING' => '',
      'rack.input' => StringIO.new,
      'rack.errors' => StringIO.new
    }
  end
end
