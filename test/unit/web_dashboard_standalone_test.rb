# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/web/dashboard/routes'
require 'rack'
require 'rack/mock'
require 'json'
require 'wurk/web'

# The dashboard under the standalone mount (`run Sidekiq::Web` without Rails):
# the engine's actions over Dashboard::Controller. Drives the standalone app
# directly, because a test process where Rails booted hands these paths to the
# engine (Wurk::Web.engine_page?).
class WebDashboardStandaloneTest < Wurk::Test::UnitCase
  INDEX = File.expand_path('../../vendor/assets/dashboard/index.html', __dir__)
  SAME_ORIGIN = { 'HTTP_SEC_FETCH_SITE' => 'same-origin' }.freeze

  def setup
    super
    Wurk::Web.reset_config!
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def test_json_api_reads_redis
    Wurk.redis { |c| c.call('LPUSH', 'queue:standalone', Wurk.dump_json(job('a'))) }
    Wurk.redis { |c| c.call('SADD', 'queues', 'standalone') }

    status, body = json(get('/api/queues/standalone'))

    assert_equal 200, status
    assert_equal 1, body['size']
    assert_equal(['a'], body['jobs'].map { |row| row['jid'] })
  end

  def test_a_json_bulk_mutation_applies_to_the_keys_it_names
    keep = add_retry('keep', 1.0)
    gone = add_retry('gone', 2.0)

    status, body = json(post('/api/retries', { cmd: 'delete', keys: [gone] }.to_json))

    assert_equal 200, status
    assert_equal({ 'ok' => true, 'count' => 1 }, body)
    assert_equal [keep.split('|').last], Wurk::RetrySet.new.map(&:jid)
  end

  def test_unknown_entry_and_bad_input_answer_as_the_engine_does
    assert_equal [404, { 'error' => 'unknown job' }], json(post('/api/retries/1.0%7Cnope', { cmd: 'retry' }.to_json))
    assert_equal [400, { 'error' => 'unknown action' }], json(post('/api/retries/all/explode', ''))
    assert_equal [400, { 'error' => 'jid required' }], json(post('/api/queues/q/delete', '{}'))
  end

  def test_unsafe_requests_need_the_same_origin
    status, _headers, body = app.call(env('POST', '/api/retries/all/delete'))

    assert_equal 403, status
    assert_equal '{"error":"cross_origin"}', body.join
  end

  # Rack lets middleware add to a response's headers; a refusal is no exception.
  def test_host_middleware_can_add_headers_to_a_refusal
    stamp = Class.new do
      def initialize(app) = @app = app

      def call(env)
        status, headers, body = @app.call(env)
        headers['x-stamp'] = '1'
        [status, headers, body]
      end
    end
    Wurk::Web.use(stamp)
    status, headers, = app.call(env('POST', '/api/retries/all/delete'))

    assert_equal [403, '1'], [status, headers['x-stamp']]
  end

  # Plain HTTP on a LAN host sends no Fetch Metadata; the engine's U9 rule
  # (Origin equal to this origin) applies on this mount too.
  def test_a_matching_origin_passes_without_fetch_metadata
    request = env('POST', '/api/retries/all/delete', input: '').merge('HTTP_ORIGIN' => 'http://example.org')
    status, = app.call(request)

    assert_equal 200, status
    assert_equal 403, app.call(request.merge('HTTP_ORIGIN' => 'http://evil.example'))[0]
  end

  def test_read_only_mode_refuses_mutations
    Wurk::Web.configure { |c| c.read_only = true }

    assert_equal 403, app.call(env('POST', '/api/retries/all/delete', input: '').merge(SAME_ORIGIN))[0]
    assert json(get('/api/meta')).last['read_only']
  end

  def test_stream_writes_server_sent_events_and_frees_its_slot
    status, headers, body = app.call(env('GET', '/api/stream?max_duration=0'))
    events = body.to_enum(:each).to_a
    body.close

    assert_equal 200, status
    assert_equal 'text/event-stream', headers['content-type']
    assert_match(/\Aretry: 2000\nevent: stats\ndata: \{.*"processed":/, events.join)
    holders = Wurk::Web::Dashboard::StreamConcurrencyGuard.instance_variable_get(:@holders)

    refute_includes holders, Thread.current
  end

  def test_redis_unavailable_is_a_structured_503
    handle = Wurk::Web::PoolScope.handle
    pool = broken_pool
    handle.define_singleton_method(:redis_pool) { pool }
    status, body = json(get('/api/stats'))

    assert_equal 503, status
    assert_equal({ 'error' => 'redis_unavailable' }, body)
  ensure
    handle.singleton_class.remove_method(:redis_pool)
  end

  def test_profile_routes_404_for_an_unlisted_key
    assert_equal 404, app.call(env('GET', '/profiles/queues/data'))[0]
  end

  def test_unknown_api_path_is_404_not_the_shell
    assert_equal 404, app.call(env('GET', '/api/v1/queues', accept: 'text/html'))[0]
  end

  def test_client_routes_get_the_shell_with_the_mount_base
    skip 'dashboard build missing (run `bin/rake frontend:build`)' unless File.exist?(INDEX)

    %w[/ /retries /ext/no-such-tab].each do |path|
      status, headers, body = app.call(env('GET', path, accept: 'text/html', script_name: '/jobs'))

      assert_equal 200, status, path
      assert_includes headers['content-type'], 'text/html'
      assert_includes body.join, 'window.__WURK_BASE__ = "/jobs";', path
    end
  end

  def test_the_bundle_is_served_under_the_mount
    skip 'dashboard build missing (run `bin/rake frontend:build`)' unless File.exist?(INDEX)

    asset = File.read(INDEX)[%r{\./(assets/[^"]+\.js)}, 1]
    status, headers, = app.call(env('GET', "/wurk-assets/#{asset}", script_name: '/jobs'))

    assert_equal 200, status
    assert_equal 'public, max-age=31536000, immutable', headers['cache-control']
    assert_equal 404, app.call(env('GET', '/wurk-assets/assets/nope.js'))[0]
  end

  private

  def app
    Wurk::Web.config.rack_app(Wurk::Web.send(:standalone_app))
  end

  def env(method, path, input: nil, accept: 'application/json', script_name: '')
    request = Rack::MockRequest.env_for(path, method: method, input: input, 'HTTP_ACCEPT' => accept,
                                              'CONTENT_TYPE' => 'application/json')
    request['SCRIPT_NAME'] = script_name
    request
  end

  def get(path) = Wurk::Web::PoolScope.scope { app.call(env('GET', path)) }
  def post(path, body) = Wurk::Web::PoolScope.scope { app.call(env('POST', path, input: body).merge(SAME_ORIGIN)) }

  def json((status, _headers, body))
    [status, JSON.parse(body.to_enum(:each).to_a.join)]
  end

  def job(jid) = { 'class' => 'StandaloneJob', 'queue' => 'standalone', 'args' => [], 'jid' => jid }

  def add_retry(jid, score)
    Wurk.redis { |c| c.call('ZADD', 'retry', score.to_s, Wurk.dump_json(job(jid).merge('retry_count' => 0))) }
    "#{score}|#{jid}"
  end

  def broken_pool
    Wurk::RedisPool.new(url: 'redis://127.0.0.1:1/0', size: 1, timeout: 0.2)
  end
end
