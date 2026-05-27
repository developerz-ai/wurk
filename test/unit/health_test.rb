# frozen_string_literal: true

require_relative '../test_helper'
require 'socket'
require 'json'

# Drives Wurk::Health::Server against a stub Launcher. Real TCP sockets,
# loopback only, port 0 so each test gets a fresh OS-assigned port — no
# parallel-test collision.
class HealthTest < Wurk::Test::UnitCase
  parallelize_me!

  class FakeRedisConn
    def initialize(response: 'PONG', raise_with: nil)
      @response = response
      @raise_with = raise_with
    end

    def call(*)
      raise @raise_with if @raise_with

      @response
    end
  end

  class FakeConfig
    attr_reader :logger

    def initialize(redis_conn: FakeRedisConn.new)
      @logger = ::Logger.new(IO::NULL)
      @redis_conn = redis_conn
    end

    def redis
      yield @redis_conn
    end
  end

  class FakeHeartbeat
    attr_reader :last_beat_at

    def initialize(last_beat_at: nil)
      @last_beat_at = last_beat_at
    end
  end

  class FakeLauncher
    def initialize(config:, heartbeat: nil, stopping: false)
      @config = config
      @heartbeat = heartbeat
      @stopping = stopping
    end

    def stopping?
      @stopping
    end
  end

  def teardown
    @server&.stop
  ensure
    super
  end

  # --- /live --------------------------------------------------------------

  def test_live_returns_200_when_launcher_running
    launcher = FakeLauncher.new(config: FakeConfig.new)
    body = get(launcher, '/live')

    assert_equal 200, body[:status_code]
    assert_equal 'ok', body[:json]['status']
    assert_equal 'live', body[:json]['check']
  end

  def test_live_returns_503_when_launcher_stopping
    launcher = FakeLauncher.new(config: FakeConfig.new, stopping: true)
    body = get(launcher, '/live')

    assert_equal 503, body[:status_code]
    assert_equal 'down', body[:json]['status']
    assert_equal 'stopping', body[:json]['reason']
  end

  # --- /ready -------------------------------------------------------------

  def test_ready_returns_200_when_redis_up_and_heartbeat_fresh
    launcher = FakeLauncher.new(
      config: FakeConfig.new,
      heartbeat: FakeHeartbeat.new(last_beat_at: ::Time.now.to_f)
    )
    body = get(launcher, '/ready')

    assert_equal 200, body[:status_code]
    assert_equal 'ok', body[:json]['status']
  end

  def test_ready_returns_503_when_redis_unreachable
    failing = FakeRedisConn.new(raise_with: RedisClient::ConnectionError.new('down'))
    launcher = FakeLauncher.new(
      config: FakeConfig.new(redis_conn: failing),
      heartbeat: FakeHeartbeat.new(last_beat_at: ::Time.now.to_f)
    )
    body = get(launcher, '/ready')

    assert_equal 503, body[:status_code]
    assert_equal 'redis unreachable', body[:json]['reason']
  end

  def test_ready_returns_503_when_heartbeat_never_fired
    launcher = FakeLauncher.new(
      config: FakeConfig.new,
      heartbeat: FakeHeartbeat.new(last_beat_at: nil)
    )
    body = get(launcher, '/ready')

    assert_equal 503, body[:status_code]
    assert_equal 'heartbeat stale', body[:json]['reason']
  end

  def test_ready_returns_503_when_heartbeat_stale
    launcher = FakeLauncher.new(
      config: FakeConfig.new,
      heartbeat: FakeHeartbeat.new(last_beat_at: ::Time.now.to_f - 60)
    )
    body = get(launcher, '/ready', ready_window: 30)

    assert_equal 503, body[:status_code]
    assert_equal 'heartbeat stale', body[:json]['reason']
  end

  # --- other paths --------------------------------------------------------

  def test_unknown_path_returns_404_json
    launcher = FakeLauncher.new(config: FakeConfig.new)
    body = get(launcher, '/something')

    assert_equal 404, body[:status_code]
    assert_equal 'error', body[:json]['status']
    assert_equal '/something', body[:json]['path']
  end

  def test_non_get_returns_405
    launcher = FakeLauncher.new(config: FakeConfig.new)
    body = request(launcher, "POST /live HTTP/1.1\r\nHost: x\r\n\r\n")

    assert_equal 405, body[:status_code]
  end

  # --- lifecycle ----------------------------------------------------------

  def test_start_idempotency_via_address_in_use
    launcher = FakeLauncher.new(config: FakeConfig.new)
    @server = build_server(launcher)
    @server.start
    port = @server.port

    # Second server on the same explicit port must not raise — logs and skips.
    second = Wurk::Health::Server.new(launcher, port: port, bind: '127.0.0.1')
    second.start

    refute_predicate second, :running?, 'second bind on busy port must skip cleanly'
  end

  def test_stop_terminates_thread_and_unbinds
    launcher = FakeLauncher.new(config: FakeConfig.new)
    @server = build_server(launcher)
    @server.start

    assert_predicate @server, :running?

    @server.stop

    refute_predicate @server, :running?
  end

  private

  # Builds a server bound on 127.0.0.1:0 (OS-assigned port) so parallel
  # tests can't collide on a fixed port.
  def build_server(launcher, ready_window: 30)
    Wurk::Health::Server.new(launcher, port: 0, bind: '127.0.0.1', ready_window: ready_window)
  end

  # Fires a single HTTP GET against a freshly-started server and parses
  # the response into { status_code:, json: }. Server is stored on @server
  # so teardown can shut it down even on test failure.
  def get(launcher, path, ready_window: 30)
    request(launcher, "GET #{path} HTTP/1.1\r\nHost: localhost\r\n\r\n", ready_window: ready_window)
  end

  def request(launcher, raw, ready_window: 30)
    @server = build_server(launcher, ready_window: ready_window)
    @server.start
    raw_response = ::TCPSocket.open('127.0.0.1', @server.port) do |s|
      s.write(raw)
      s.read
    end
    parse_response(raw_response)
  end

  def parse_response(raw)
    head, body = raw.split("\r\n\r\n", 2)
    status_code = head.lines.first.split(' ', 3)[1].to_i
    { status_code: status_code, json: ::JSON.parse(body) }
  end
end
