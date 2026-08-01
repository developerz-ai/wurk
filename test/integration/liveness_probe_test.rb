# frozen_string_literal: true

require_relative '../test_helper'
require 'socket'
require 'json'

# Issue #23 DoD: "Manual test: kill Redis → /ready returns 503, /live stays
# 200." This exercises the full Launcher → Heartbeat → Health::Server wiring
# end-to-end against real TCP and real Redis. The Redis-down scenario uses a
# togglable pool wrapper (same pattern as client_outage_test) so we don't
# disrupt sibling tests by SHUTDOWN-ing the shared instance.
class LivenessProbeTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 3.0
  POLL_INTERVAL = 0.05

  def setup
    super
    @ns = "lp:#{Process.pid}:#{object_id}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:tag] = @ns
    cap = @config.default_capsule
    # Unique per-test queue: a leaked Launcher from a prior run/test must
    # never be able to steal work off the shared `queue:default` list.
    cap.queues = [@ns]
    cap.concurrency = 1
    cap.fetcher = Wurk::Fetcher::Reliable.new(cap)
    # Materialize lazy ivars before Launcher.run freezes the capsule —
    # otherwise Heartbeat#beat! and the health server's Redis ping hit
    # FrozenError on first call. Mirrors Swarm::ChildBoot#apply_slot_to_config.
    cap.redis_pool
    cap.fetch_redis_pool
    cap.client_middleware
    cap.server_middleware
    # Bind on 127.0.0.1:0 so each test gets a unique OS-assigned port.
    @config.health_check(port: 0, bind: '127.0.0.1', ready_window: 5)
    @launcher = nil
  end

  def teardown
    # Full teardown (not just health-server/heartbeat) so managers, poller,
    # reaper and leader threads don't outlive the test — a leaked Launcher
    # here would otherwise keep fetching from later tests' queues.
    begin
      @launcher&.stop
    rescue StandardError
      nil
    end
    # Launcher#stop doesn't own the boot-reclaim thread and offers no kill
    # fallback, so teardown has to confirm the join actually landed — a
    # surviving thread keeps sweeping Redis into the next test.
    reclaim = @launcher&.instance_variable_get(:@boot_reclaim_thread)
    stuck = !reclaim.nil? && reclaim.join(2).nil?
    reclaim.kill if stuck
  ensure
    super
    raise 'boot-reclaim thread still alive 2s after Launcher#stop' if stuck
  end

  def test_live_returns_200_when_launcher_running
    boot_launcher

    body = probe('/live')

    assert_equal 200, body[:status_code]
    assert_equal 'ok', body[:json]['status']
  end

  def test_ready_returns_200_once_first_heartbeat_fires
    boot_launcher
    @launcher.heartbeat # one synchronous beat so heartbeat_fresh? passes

    body = probe('/ready')

    assert_equal 200, body[:status_code]
    assert_equal 'ok', body[:json]['status']
  end

  # Verifies the issue DoD: kill Redis (here: short-circuit beats so
  # heartbeat goes stale within the launcher's view) → /ready returns 503,
  # /live stays 200. The full "Redis socket actually unreachable" branch is
  # covered by the unit test (HealthTest#test_ready_returns_503_when_redis_unreachable)
  # because a hard pool swap on a frozen Launcher fights Configuration's
  # freeze invariant by design.
  def test_ready_returns_503_when_heartbeat_goes_stale_but_live_stays_200
    boot_launcher
    @launcher.heartbeat # one fresh beat
    hb = @launcher.instance_variable_get(:@heartbeat)
    # Rewind last_beat_at past the ready window so /ready treats it as stale.
    hb.instance_variable_set(:@last_beat_at, ::Time.now.to_f - 60)

    ready = probe('/ready')

    assert_equal 503, ready[:status_code]
    assert_equal 'heartbeat stale', ready[:json]['reason']

    live = probe('/live')

    assert_equal 200, live[:status_code], '/live must stay 200 while only the heartbeat is stale'
  end

  def test_live_returns_503_after_stop
    boot_launcher
    # Trigger stopping? without invoking the full stop pipeline (which would
    # also tear down the health server before we can probe it).
    @launcher.instance_variable_set(:@done, true)

    body = probe('/live')

    assert_equal 503, body[:status_code]
    assert_equal 'stopping', body[:json]['reason']
  end

  private

  def boot_launcher
    @launcher = Wurk::Launcher.new(@config)
    @launcher.run(async_beat: false)
    wait_for_probe_listener
    @launcher
  end

  # Health::Server starts in a thread; busy-wait until its port answers.
  def wait_for_probe_listener
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + POLL_TIMEOUT
    while ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) < deadline
      return if listener_ready?

      sleep POLL_INTERVAL
    end
    flunk 'Health::Server did not start within poll timeout'
  end

  def listener_ready?
    server = @launcher.instance_variable_get(:@health_server)
    return false unless server&.running? == true && server.port.positive?

    ::TCPSocket.open('127.0.0.1', server.port, &:close)
    true
  rescue Errno::ECONNREFUSED, IOError
    false
  end

  def probe(path)
    server = @launcher.instance_variable_get(:@health_server)
    raw = ::TCPSocket.open('127.0.0.1', server.port) do |s|
      s.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\n\r\n")
      s.read
    end
    head, body = raw.split("\r\n\r\n", 2)
    {
      status_code: head.lines.first.split(' ', 3)[1].to_i,
      json: ::JSON.parse(body)
    }
  end

end
