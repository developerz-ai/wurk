# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api/app'
require 'stringio'
require 'logger'

# Slice 07 — the Wurk::API Rack app skeleton: versioned under /v1, mount-
# agnostic (every emitted URL derives from SCRIPT_NAME), RFC-9457-shaped
# problem bodies. Route tables for jobs/queues/swarm land in later slices.
#
# Auth is exercised in api_auth_test.rb; every request here carries a valid
# admin token so these tests speak only about routing and error shape.
class ApiAppTest < Wurk::Test::UnitCase
  parallelize_me!

  LIB = File.expand_path('../../lib', __dir__)
  TOKEN = 'api-app-test-token-0123456789'

  def test_version_root_reports_the_contract_it_serves
    status, headers, body = get('/v1')

    assert_equal 200, status
    assert_equal 'application/json', headers['content-type']
    assert_equal 'v1', body['api_version']
    assert_equal Wurk::VERSION, body['wurk_version']
  end

  def test_every_response_forbids_content_sniffing
    _status, ok_headers, = get('/v1')
    _status, problem_headers, = get('/v1/nope')

    assert_equal 'nosniff', ok_headers['x-content-type-options']
    assert_equal 'nosniff', problem_headers['x-content-type-options']
  end

  # The mount-agnostic contract: '/wurk' appears nowhere in lib/wurk/api.
  def test_emitted_url_is_derived_from_the_mount_point
    _status, _headers, body = get('/v1', script_name: '/wurk/api')

    assert_equal '/wurk/api/v1', body['url']
  end

  def test_emitted_url_follows_a_separate_mount
    _status, _headers, body = get('/v1', script_name: '/wurk-api')

    assert_equal '/wurk-api/v1', body['url']
  end

  def test_emitted_url_is_bare_when_mounted_at_the_root
    _status, _headers, body = get('/v1')

    assert_equal '/v1', body['url']
  end

  def test_trailing_slash_reaches_the_version_root
    status, = get('/v1/')

    assert_equal 200, status
  end

  def test_unknown_route_under_the_served_version_is_a_not_found_problem
    status, headers, body = get('/v1/nope')

    assert_equal 404, status
    assert_equal 'application/problem+json', headers['content-type']
    assert_equal 'not_found', body['type']
    assert_equal 'Not Found', body['title']
    assert_equal 404, body['status']
  end

  # `instance` is the request path as the client addressed it, mount included —
  # a client behind a shared proxy needs to know which mount answered.
  def test_problem_instance_carries_the_mounted_request_path
    _status, _headers, body = get('/v1/nope', script_name: '/wurk/api')

    assert_equal '/wurk/api/v1/nope', body['instance']
  end

  def test_unknown_version_names_the_versions_that_exist
    status, _headers, body = get('/v2/jobs')

    assert_equal 404, status
    assert_equal 'unsupported_api_version', body['type']
    assert_equal ['v1'], body['supported_versions']
  end

  def test_unversioned_path_is_an_unsupported_version_problem
    status, _headers, body = get('/jobs')

    assert_equal 404, status
    assert_equal 'unsupported_api_version', body['type']
  end

  def test_app_root_does_not_serve_the_version_root
    status, _headers, body = get('/')

    assert_equal 404, status
    assert_equal 'unsupported_api_version', body['type']
  end

  # A '/v1abc' prefix is not a version segment; only '/v1' and '/v1/…' are.
  def test_version_prefix_matches_whole_segments_only
    status, _headers, body = get('/v1abc')

    assert_equal 404, status
    assert_equal 'unsupported_api_version', body['type']
  end

  def test_wrong_verb_on_a_known_path_is_405_with_allow
    status, headers, body = call(env_for('POST', '/v1'))

    assert_equal 405, status
    assert_equal 'GET, HEAD', headers['allow']
    assert_equal 'method_not_allowed', JSON.parse(body.join)['type']
  end

  def test_allow_advertises_only_the_verbs_the_path_answers
    _status, headers, = RoutesApp.new(config: config).call(env_for('GET', '/v1/create'))

    assert_equal 'POST', headers['allow']
  end

  def test_router_captures_reach_the_handler_decoded
    _status, _headers, body = RoutesApp.new(config: config).call(env_for('GET', '/v1/echo/two%20words'))

    assert_equal 'two words', JSON.parse(body.join)['echoed']
  end

  def test_head_routes_as_get_but_sends_no_body
    status, headers, body = call(env_for('HEAD', '/v1'))

    assert_equal 200, status
    assert_equal 'application/json', headers['content-type']
    assert_empty body
  end

  def test_handler_failure_becomes_a_problem_without_leaking_the_exception
    status, headers, body = BoomApp.new(config: config).call(env_for('GET', '/v1'))

    assert_equal 500, status
    assert_equal 'application/problem+json', headers['content-type']
    payload = JSON.parse(body.join)

    assert_equal 'internal_error', payload['type']
    refute_includes payload.to_s, 'kaboom'
  end

  def test_handler_failure_is_logged_server_side
    log = capture_log do
      BoomApp.new(config: config).call(env_for('GET', '/v1', script_name: '/wurk/api'))
    end

    assert_includes log, 'kaboom'
    assert_includes log, 'GET /wurk/api/v1'
  end

  # `mount Wurk::API => …` and `run Wurk::API` both go through this entry, which
  # reads the process-wide config — hence the global-state mutex and the
  # deregistration in `ensure`.
  def test_module_level_rack_entry_serves_the_same_routes
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      Wurk.configuration.api_token(TOKEN, scopes: %i[read])
      status, _headers, body = Wurk::API.call(env_for('GET', '/v1'))

      assert_equal 200, status
      assert_equal 'v1', JSON.parse(body.join)['api_version']
    ensure
      Wurk.configuration.api_tokens.delete(TOKEN)
    end
  end

  # The additive invariant: a swarm that never serves HTTP must not carry the
  # router or Rack::Request in its pre-fork heap. Subprocess, because this
  # process has already required the app.
  def test_requiring_wurk_does_not_load_the_http_api
    loaded = ruby('require "wurk"; print $LOADED_FEATURES.grep(%r{wurk/api/(app|auth|router|request)\.rb\z}).size')

    assert_equal '0', loaded
  end

  def test_the_mount_point_loads_the_app_on_first_request
    loaded = ruby(<<~RUBY)
      require 'wurk'
      Wurk::API.call('REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/v1', 'SCRIPT_NAME' => '')
      print $LOADED_FEATURES.grep(%r{wurk/api/(app|auth|router|request)\\.rb\\z}).size
    RUBY

    assert_equal '4', loaded
  end

  private

  # An App whose only route raises, to exercise the 500 path.
  class BoomApp < Wurk::API::App
    private

    def draw(router)
      router.get('/', scope: Wurk::API::Auth::ANY) { raise 'kaboom' }
    end
  end

  # A second route table for the router↔request wiring the skeleton's own root
  # route can't reach: a capture arriving at a handler, and a path with no GET.
  class RoutesApp < Wurk::API::App
    private

    def draw(router)
      router.get('/echo/:name', scope: :read) { |request| json(200, echoed: request.path_params[:name]) }
      router.post('/create', scope: :enqueue) { |_request| json(201, created: true) }
    end
  end

  def call(env) = Wurk::API::App.new(config: config).call(env)

  def config
    @config ||= Wurk::Configuration.new.tap { |cfg| cfg.api_token(TOKEN, scopes: %i[admin]) }
  end

  def ruby(script)
    IO.popen([RbConfig.ruby, '-I', LIB, '-e', script], err: %i[child out], &:read)
  end

  def get(path, script_name: '')
    status, headers, body = call(env_for('GET', path, script_name: script_name))
    [status, headers, JSON.parse(body.join)]
  end

  def env_for(method, path, script_name: '')
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => script_name,
      'QUERY_STRING' => '',
      'HTTP_AUTHORIZATION' => "Bearer #{TOKEN}",
      'rack.input' => StringIO.new,
      'rack.errors' => StringIO.new
    }
  end

  # Swaps the process-global logger, so it takes the suite-wide mutex the other
  # global-state tests use rather than racing a parallel class's own swap.
  def capture_log
    io = StringIO.new
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
      previous = Wurk.logger
      Wurk.logger = ::Logger.new(io)
      begin
        yield
      ensure
        Wurk.logger = previous
      end
    end
    io.string
  end
end
