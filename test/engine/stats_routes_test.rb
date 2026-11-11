# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'json'
require 'sidekiq/web'

# The engine mount serves Sidekiq Web's machine-readable routes (free §25.4)
# with upstream's shapes; test/parity/web_stats_routes_test.rb pins the shapes
# on the Rails-free entry. These pin the wiring: `mount Wurk::Engine` and, in a
# Rails app, `mount Sidekiq::Web` both reach them, behind the engine's gates.
class StatsRoutesTest < Wurk::Test::EngineCase
  def setup
    super
    Wurk::Web.reset_config!
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def test_head_root_answers_without_the_spa_shell
    head '/wurk/'

    assert_equal 200, last_response.status
    # The SPA shell would answer `text/html; charset=utf-8` from a controller.
    assert_equal 'text/html', last_response.content_type, 'HEAD / rendered the SPA shell'
  end

  def test_get_root_still_renders_the_dashboard
    get '/wurk', {}, 'HTTP_ACCEPT' => 'text/html'

    assert_equal 200, last_response.status
    assert_includes last_response.body, '<div id="wurk-root">'
  end

  def test_stats_and_stats_queues_answer_json_for_any_accept
    get '/wurk/stats', {}, 'HTTP_ACCEPT' => 'text/html'

    assert_equal 200, last_response.status
    assert_equal %w[redis server_utc_time sidekiq], JSON.parse(last_response.body).keys.sort

    get '/wurk/stats/queues'

    assert_equal 200, last_response.status
    assert_kind_of Hash, JSON.parse(last_response.body)
  end

  def test_dashboard_stats_redirects_under_the_mount
    get '/wurk/dashboard/stats'

    assert_equal 302, last_response.status
    assert_equal 'http://example.org/wurk/stats', last_response.headers['location']
  end

  def test_sidekiq_web_mount_reaches_the_stats_route
    env = ::Rack::MockRequest.env_for('http://example.org/sidekiq/stats')
    env['SCRIPT_NAME'] = '/sidekiq'
    env['PATH_INFO'] = '/stats'
    status, _headers, body = Sidekiq::Web.call(env)
    text = +''
    body.each { |chunk| text << chunk }

    assert_equal 200, status
    assert_includes JSON.parse(text).keys, 'sidekiq'
  end

  def test_the_authorization_hook_gates_stats
    Sidekiq::Web.configure { |c| c.authorization { |_env, _method, _path| false } }

    get '/wurk/stats'

    assert_equal 403, last_response.status
  end
end
