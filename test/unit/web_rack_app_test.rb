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
