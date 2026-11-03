# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'sidekiq/web'

# `mount Sidekiq::Web` is the stock install line, so it has to show the dashboard.
# Every test here also pins that this entry is no way around a gate: `Wurk::Web.call`
# is exactly what the mount calls, with the mount's SCRIPT_NAME.
class SidekiqWebMountTest < Wurk::Test::EngineCase
  module OneRoute
    def self.registered(app)
      app.get('/one-route') { 'from the extension' }
      app.post('/one-route') { 'posted' }
    end
  end

  MOUNT = '/sidekiq'
  # Rails serves the SPA catch-all only to a browser's Accept.
  HTML = { 'HTTP_ACCEPT' => 'text/html' }.freeze

  def setup
    super
    Wurk::Web.reset_config!
    Wurk::Web.register(OneRoute, name: 'one', tab: 'One', index: 'one-route')
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def call_mount(path, method: 'GET', headers: HTML)
    env = ::Rack::MockRequest.env_for("http://example.org#{MOUNT}#{path}", method: method).merge(headers)
    env['SCRIPT_NAME'] = MOUNT
    env['PATH_INFO'] = path
    status, response_headers, body = Sidekiq::Web.call(env)
    text = +''
    body.each { |chunk| text << chunk }
    body.close if body.respond_to?(:close)
    [status, response_headers, text]
  end

  def test_the_root_shows_the_dashboard
    status, _headers, body = call_mount('/')

    assert_equal 200, status
    assert_includes body, '<div id="wurk-root">'
    assert_includes body, '<script>window.__WURK_BASE__ = "/sidekiq";</script>'
  end

  def test_a_dashboard_page_shows_the_dashboard
    status, _headers, body = call_mount('/retries')

    assert_equal 200, status
    assert_includes body, '<div id="wurk-root">'
  end

  def test_the_json_api_answers_under_this_mount
    status, _headers, body = call_mount('/api/stats', headers: {})

    assert_equal 200, status
    assert_kind_of Hash, JSON.parse(body)
  end

  def test_the_machine_api_is_not_served_under_this_mount
    token = 'wurk-mount-test-token'
    Wurk.configuration.api_token(token, scopes: %i[read])

    assert ::Wurk::API.engine_serves?('/api/v1/queues'), 'a token has to exist for this to prove anything'

    %w[/api/v1/queues /api/v2/queues].each do |path|
      assert_equal 404, call_mount(path, headers: { 'HTTP_AUTHORIZATION' => "Bearer #{token}" })[0], path
    end
  ensure
    Wurk.configuration.api_tokens.clear
  end

  def test_an_extension_route_is_still_the_extensions
    status, _headers, body = call_mount('/one-route')

    assert_equal 200, status
    assert_equal 'from the extension', body
  end

  def test_a_mutating_dashboard_request_needs_the_same_origin_header
    assert_equal 403, call_mount('/api/retries/all/delete', method: 'POST', headers: {})[0]
  end

  def test_a_mutating_extension_request_needs_the_same_origin_header
    assert_equal 403, call_mount('/one-route', method: 'POST', headers: {})[0]
    assert_equal 200, call_mount('/one-route', method: 'POST', headers: { 'HTTP_SEC_FETCH_SITE' => 'same-origin' })[0]
  end

  PATHS = ['/', '/retries', '/api/stats', '/one-route'].freeze

  def test_authorization_denies_every_path_on_this_mount_and_on_the_engine
    Wurk::Web.configure { |c| c.authorization { |_env, _method, _path| false } }

    PATHS.each do |path|
      assert_equal 403, call_mount(path)[0], path

      get "/wurk#{path}", {}, HTML

      assert_equal 403, last_response.status, "engine #{path}" unless path == '/one-route'
    end
  end

  def test_host_middleware_denies_every_path_on_this_mount_and_on_the_engine
    Wurk::Web.use(::Rack::Auth::Basic) { |_user, password| password == 'right' }

    PATHS.each do |path|
      assert_equal 401, call_mount(path)[0], path

      get "/wurk#{path}", {}, HTML

      assert_equal 401, last_response.status, "engine #{path}"
    end
  end

  def test_host_middleware_lets_the_right_credentials_through
    Wurk::Web.use(::Rack::Auth::Basic) { |_user, password| password == 'right' }
    credentials = { 'HTTP_AUTHORIZATION' => "Basic #{['u:right'].pack('m0')}" }

    PATHS.each { |path| assert_equal 200, call_mount(path, headers: HTML.merge(credentials))[0], path }
  end

  # What a host writes when it guards the route itself. Stands in front of the
  # dispatch, so it holds whichever side of it a path lands on.
  def test_a_wrapper_around_sidekiq_web_still_applies
    wrapped = ::Rack::Auth::Basic.new(Sidekiq::Web) { |_user, password| password == 'right' }

    PATHS.each do |path|
      env = ::Rack::MockRequest.env_for("http://example.org#{MOUNT}#{path}").merge(HTML)
      env['SCRIPT_NAME'] = MOUNT
      env['PATH_INFO'] = path

      assert_equal 401, wrapped.call(env)[0], path
    end
  end

  def test_read_only_mode_holds_on_this_mount
    Wurk::Web.configure { |c| c.read_only = true }
    headers = { 'HTTP_SEC_FETCH_SITE' => 'same-origin' }

    assert_equal 403, call_mount('/api/retries/all/delete', method: 'POST', headers: headers)[0]
    assert_equal 403, call_mount('/one-route', method: 'POST', headers: headers)[0]
  end
end
