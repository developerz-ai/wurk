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

    def initialize(redis_conn: FakeRedisConn.new, logger: ::Logger.new(IO::NULL))
      @logger = logger
      @redis_conn = redis_conn
    end

    def redis
      yield @redis_conn
    end
  end

  # A heartbeat-shaped object that does NOT respond to #last_beat_at, to drive
  # the "respond_to?(:last_beat_at)" guard's false branch independently of the
  # nil-heartbeat path.
  class HeartbeatWithoutLastBeat
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

  def test_second_bind_on_busy_port_polls_instead_of_serving
    launcher = FakeLauncher.new(config: FakeConfig.new)
    @server = build_server(launcher)
    @server.start
    port = @server.port

    # Second server on the same explicit port must not raise; it polls to take
    # the port over rather than serving or giving up.
    second = Wurk::Health::Server.new(launcher, port: port, bind: '127.0.0.1', retry_interval: 0.05)
    second.start
    begin
      refute_predicate second, :running?, 'second bind on busy port must not serve yet'
      assert_predicate second, :retrying?, 'second must poll to take the port over'
    ensure
      second.stop
    end

    refute_predicate second, :retrying?, 'stop cancels the retry poll'
  end

  def test_second_child_takes_over_port_after_owner_stops
    launcher = FakeLauncher.new(config: FakeConfig.new)
    first = build_server(launcher)
    first.start
    port = first.port

    @server = Wurk::Health::Server.new(launcher, port: port, bind: '127.0.0.1', retry_interval: 0.05)
    @server.start

    refute_predicate @server, :running?, 'the non-owner must not serve while the owner holds the port'

    first.stop # frees the port

    assert wait_until { @server.running? },
           'the survivor must bind the shared port within a retry interval of the owner exiting'
  ensure
    first&.stop
  end

  def test_stop_terminates_thread_and_unbinds
    launcher = FakeLauncher.new(config: FakeConfig.new)
    @server = build_server(launcher)
    @server.start

    assert_predicate @server, :running?

    @server.stop

    refute_predicate @server, :running?
  end

  # --- /ready heartbeat guard branches -----------------------------------

  def test_ready_returns_503_when_heartbeat_absent
    # No heartbeat at all (default nil): hb&.respond_to? short-circuits on nil.
    launcher = FakeLauncher.new(config: FakeConfig.new)
    body = get(launcher, '/ready')

    assert_equal 503, body[:status_code]
    assert_equal 'heartbeat stale', body[:json]['reason']
  end

  def test_ready_returns_503_when_heartbeat_lacks_last_beat_at
    # Heartbeat object present but does not respond to #last_beat_at: drives the
    # respond_to? false branch with a non-nil receiver.
    launcher = FakeLauncher.new(config: FakeConfig.new, heartbeat: HeartbeatWithoutLastBeat.new)
    body = get(launcher, '/ready')

    assert_equal 503, body[:status_code]
    assert_equal 'heartbeat stale', body[:json]['reason']
  end

  # --- logger-nil branches (logger&.warn / logger&.error / @config&.logger) --

  def test_address_in_use_with_nil_config_logger_does_not_raise
    # @config is nil → logger returns nil (the else side of `@config&.logger`)
    # → logger&.warn in start_retry_loop short-circuits without raising.
    launcher = FakeLauncher.new(config: nil)
    @server = build_server(launcher)
    @server.start
    port = @server.port

    second = Wurk::Health::Server.new(launcher, port: port, bind: '127.0.0.1', retry_interval: 0.05)
    second.start
    begin
      refute_predicate second, :running?
    ensure
      second.stop
    end
  end

  def test_address_in_use_with_present_config_but_nil_logger_does_not_raise
    # @config present but its #logger is nil → `@config&.logger` then-side
    # returns nil → logger&.warn short-circuits. Distinct from the nil-config
    # case above so both sides of @config&.logger are exercised.
    launcher = FakeLauncher.new(config: FakeConfig.new(logger: nil))
    @server = build_server(launcher)
    @server.start
    port = @server.port

    second = Wurk::Health::Server.new(launcher, port: port, bind: '127.0.0.1', retry_interval: 0.05)
    second.start
    begin
      refute_predicate second, :running?
    ensure
      second.stop
    end
  end

  # --- write_response default reason branch ------------------------------

  def test_write_response_uses_generic_reason_for_unmapped_status
    server = Wurk::Health::Server.new(FakeLauncher.new(config: FakeConfig.new))
    sock = StringIO.new
    server.send(:write_response, sock, 418, '{"status":"teapot"}')
    sock.rewind
    head = sock.read.lines.first

    assert_equal 'HTTP/1.1 418 Status', head.strip
  end

  # --- accept loop: idle poll timeout (line 81 "next") --------------------

  def test_server_idles_through_select_timeouts_then_serves
    # Start the server and let it spin through several ACCEPT_TIMEOUT IO.select
    # timeouts (no connection) before a request arrives. This exercises the
    # `next unless ready` path in #run deterministically.
    launcher = FakeLauncher.new(config: FakeConfig.new)
    @server = build_server(launcher)
    @server.start

    # Three ACCEPT_TIMEOUT (0.2s) cycles with no client → several `next`s.
    sleep_until_quiet

    raw = ::TCPSocket.open('127.0.0.1', @server.port) do |s|
      s.write("GET /live HTTP/1.1\r\nHost: x\r\n\r\n")
      s.read
    end

    assert_equal 200, parse_response(raw)[:status_code]
  end

  # --- handle: client sends nothing (line 98 return) ----------------------

  def test_client_that_sends_no_request_is_closed_without_response
    # Connect, send nothing, let the 1.0s read-wait in #handle expire so it
    # returns early. The server must close the socket and stay healthy.
    launcher = FakeLauncher.new(config: FakeConfig.new)
    @server = build_server(launcher)
    @server.start

    silent = ::TCPSocket.open('127.0.0.1', @server.port)
    # No write. Read returns EOF once the server gives up and closes us.
    leftover = silent.read
    silent.close

    assert_empty leftover, 'silent client should receive no response body'

    # Server still serves a subsequent real request.
    raw = ::TCPSocket.open('127.0.0.1', @server.port) do |s|
      s.write("GET /live HTTP/1.1\r\nHost: x\r\n\r\n")
      s.read
    end

    assert_equal 200, parse_response(raw)[:status_code]
  end

  # --- handle: header-drain loop select timeout (line 107 break) ----------

  def test_request_with_no_trailing_headers_still_gets_response
    # Send a complete, CRLF-terminated request line and then NOTHING else (no
    # blank line, socket kept open). The header-drain loop's first IO.select
    # (1.0s) finds no further bytes and times out → `break` → the request is
    # answered from the request line alone.
    launcher = FakeLauncher.new(config: FakeConfig.new)
    @server = build_server(launcher)
    @server.start

    raw = ::TCPSocket.open('127.0.0.1', @server.port) do |s|
      s.write("GET /live HTTP/1.1\r\n")
      # Keep the socket open (no further write) so the drain loop must wait and
      # time out rather than see EOF. read blocks until the server responds.
      s.read
    end

    assert_equal 200, parse_response(raw)[:status_code]
  end

  private

  # Spins long enough for the accept thread to traverse multiple
  # ACCEPT_TIMEOUT IO.select cycles with no inbound connection.
  def sleep_until_quiet
    deadline = ::Time.now + 0.7
    Kernel.sleep(0.05) while ::Time.now < deadline
  end

  # Polls the block until it returns truthy or the timeout elapses; returns the
  # block's final value so callers can assert on it.
  def wait_until(timeout = 2)
    deadline = ::Time.now + timeout
    sleep 0.02 until yield || ::Time.now > deadline
    yield
  end

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
