# frozen_string_literal: true

require_relative '../test_helper'
require 'delegate'
require 'json'
require 'rack'
require 'stringio'

# Parity oracle for Sidekiq Web's machine-readable routes,
# docs/target/sidekiq-free.md §25.1 and §25.4:
#
# - `HEAD /` is the health check: it reaches Redis (`LLEN queue:default`).
# - `GET /stats` answers JSON with `sidekiq`, `redis` and `server_utc_time`.
# - `GET /stats/queues` answers JSON queue sizes.
# - `GET /dashboard/stats` redirects (302) to `/stats`.
#
# The member names inside `sidekiq` and `redis` are the ones upstream's
# /stats handler emits (sidekiq 8.1.6 lib/sidekiq/web/application.rb):
# uptime monitors and scripts against `/sidekiq/stats` read exactly these.
# Driven through the Rails-free `Sidekiq::Web.call`, the `run Sidekiq::Web`
# entry; test/engine/stats_routes_test.rb covers the engine mount.
class WebStatsRoutesParityTest < Wurk::Test::UnitCase
  SIDEKIQ_KEYS = %w[processed failed busy processes enqueued scheduled retries dead default_latency].freeze
  REDIS_KEYS = %w[redis_version uptime_in_days connected_clients used_memory_human used_memory_peak_human
                  store_name store_version].freeze

  def setup
    super
    Wurk::Web.reset_config!
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def test_head_root_is_a_redis_health_check
    commands = []
    pool = Wurk.configuration.web_redis_pool
    pool.singleton_class.prepend(command_recorder(commands))

    status, _headers, body = call_web('HEAD', '/', script_name: '/sidekiq')

    assert_equal 200, status
    assert_equal '', join(body)
    assert_includes commands, ['LLEN', 'queue:default'], 'HEAD / did not reach Redis'
  ensure
    Wurk.configuration.reset_redis_pools!
  end

  def test_stats_answers_upstream_shape
    Wurk.redis do |conn|
      conn.call('SET', 'stat:processed', '7')
      conn.call('SET', 'stat:failed', '2')
      conn.call('SADD', 'queues', 'default')
      conn.call('LPUSH', 'queue:default', JSON.generate('class' => 'X', 'jid' => 'j1', 'args' => []))
    end

    status, headers, body = call_web('GET', '/stats')
    payload = JSON.parse(join(body))

    assert_equal 200, status
    assert_equal 'application/json', header(headers, 'content-type')
    assert_equal %w[redis server_utc_time sidekiq], payload.keys.sort
    assert_equal SIDEKIQ_KEYS.sort, payload['sidekiq'].keys.sort
    assert_equal REDIS_KEYS.sort, payload['redis'].keys.sort
    assert_equal 7, payload['sidekiq']['processed']
    assert_equal 2, payload['sidekiq']['failed']
    assert_equal 1, payload['sidekiq']['enqueued']
    assert_includes %w[Redis Valkey Dragonfly], payload['redis']['store_name']
    assert_match(/\A\d\d:\d\d:\d\d UTC\z/, payload['server_utc_time'])
  end

  def test_stats_queues_answers_name_to_size
    Wurk.redis do |conn|
      conn.call('SADD', 'queues', 'a', 'b')
      conn.call('LPUSH', 'queue:a', 'x', 'y')
      conn.call('LPUSH', 'queue:b', 'z')
    end

    status, headers, body = call_web('GET', '/stats/queues')

    assert_equal 200, status
    assert_equal 'application/json', header(headers, 'content-type')
    assert_equal({ 'a' => 2, 'b' => 1 }, JSON.parse(join(body)))
  end

  def test_dashboard_stats_redirects_to_stats
    status, headers, = call_web('GET', '/dashboard/stats', script_name: '/sidekiq')

    assert_equal 302, status
    assert_equal 'http://example.org/sidekiq/stats', header(headers, 'location')
  end

  # The routes sit behind the dashboard's gates, as upstream's do.
  def test_a_falsey_authorization_block_refuses_stats
    Sidekiq::Web.configure { |c| c.authorization { |_env, _method, _path| false } }

    status, = call_web('GET', '/stats')

    assert_equal 403, status
  end

  private

  # Records every command sent through the pool's connections.
  def command_recorder(commands)
    Module.new do
      define_method(:with) do |**kw, &blk|
        super(**kw) do |conn|
          recorder = SimpleDelegator.new(conn)
          recorder.define_singleton_method(:call) do |*args, **opts|
            commands << args.first(2)
            __getobj__.call(*args, **opts)
          end
          blk.call(recorder)
        end
      end
    end
  end

  def call_web(method, path, script_name: '')
    env = ::Rack::MockRequest.env_for("http://example.org#{script_name}#{path}", method: method)
    env['SCRIPT_NAME'] = script_name
    env['PATH_INFO'] = path
    Sidekiq::Web.call(env)
  end

  def join(body)
    text = +''
    body.each { |chunk| text << chunk }
    text
  end

  def header(headers, name)
    headers.find { |key, _| key.casecmp?(name) }&.last
  end
end
