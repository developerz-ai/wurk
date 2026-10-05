# frozen_string_literal: true

require_relative '../test_helper'
require 'socket'
require 'json'

# The health listener's /metrics endpoint and the swarm half of /ready, against
# real Redis and a real loopback socket (port 0 — no parallel collisions).
class HealthMetricsTest < Wurk::Test::UnitCase
  parallelize_me!

  class FakeHeartbeat
    def last_beat_at = ::Time.now.to_f
  end

  class FakeLauncher
    def initialize(config)
      @config = config
      @heartbeat = FakeHeartbeat.new
    end

    def stopping? = false
  end

  def setup
    @config = Wurk::Configuration.new
    @config.redis = { url: Wurk::Test.redis_url }
    @config.logger = ::Logger.new(IO::NULL)
    @redis = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @server&.stop
    Wurk::Health.fleet_size = nil
    @redis&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_metrics_serves_prometheus_text
    @redis.call('SET', 'stat:processed', '5')
    status, headers, body = get('/metrics')

    assert_equal 200, status
    assert_equal Wurk::Metrics::Prometheus::CONTENT_TYPE, headers['content-type']
    assert_includes body, "wurk_processed_total 5\n"
    assert_includes body, "# TYPE wurk_build_info gauge\n"
    assert_equal body.bytesize, headers['content-length'].to_i
  end

  def test_metrics_can_be_switched_off
    @config[:health_check_options] = { port: 0, metrics: false }
    status, headers, = get('/metrics')

    assert_equal 404, status
    assert_equal 'application/json', headers['content-type']
  end

  def test_ready_outside_a_swarm_ignores_siblings
    status, _, body = get('/ready')

    assert_equal 200, status
    refute JSON.parse(body).key?('expected')
  end

  def test_ready_needs_half_the_fleet_fresh
    Wurk::Health.fleet_size = 4
    sibling(1, age: 1)
    sibling(2, age: 500) # stale: beat long outside ready_window

    status, _, body = get('/ready')
    json = JSON.parse(body)

    assert_equal 503, status
    assert_equal 'too few live children', json['reason']
    assert_equal [1, 2, 4], json.values_at('children', 'needed', 'expected')
  end

  def test_ready_when_half_the_fleet_is_fresh
    Wurk::Health.fleet_size = 3
    sibling(1, age: 1)
    sibling(2, age: 2)
    foreign(3) # another swarm's child on the same host does not count

    status, _, body = get('/ready')

    assert_equal 200, status
    assert_equal 2, JSON.parse(body)['children']
  end

  def test_min_ready_option_overrides_the_default
    @config[:health_check_options] = { port: 0, min_ready: 3 }
    Wurk::Health.fleet_size = 4
    sibling(1, age: 1)
    sibling(2, age: 1)

    status, _, body = get('/ready')

    assert_equal 503, status
    assert_equal 3, JSON.parse(body)['needed']
  end

  private

  def sibling(pid, age:)
    beat("#{Wurk::Component.hostname}:#{pid}:#{Wurk::Component::PROCESS_NONCE}", age)
  end

  def foreign(pid)
    beat("#{Wurk::Component.hostname}:#{pid}:ffffffffffff", 1)
  end

  def beat(identity, age)
    @redis.call('SADD', 'processes', identity)
    @redis.call('HSET', identity, 'busy', 0, 'concurrency', 5, 'beat', (Time.now.to_f - age).to_s)
  end

  def get(path)
    @server = Wurk::Health::Server.new(FakeLauncher.new(@config), port: 0, bind: '127.0.0.1')
    @server.start
    raw = ::TCPSocket.open('127.0.0.1', @server.port) do |s|
      s.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\n\r\n")
      s.read
    end
    head, body = raw.split("\r\n\r\n", 2)
    lines = head.lines(chomp: true)
    headers = lines.drop(1).to_h do |l|
      k, v = l.split(': ', 2)
      [k.downcase, v]
    end
    [lines.first.split(' ', 3)[1].to_i, headers, body]
  end
end
