# frozen_string_literal: true

require_relative '../test_helper'
require 'net/http'
require 'socket'

# Real forks, real Redis, a real health listener: a SIGKILLed child shows up
# as `reason="crash"` on the /metrics its replacement serves, so the counter
# lives in the parent and survives the child that counted it. NEVER mock Redis.
class SwarmRestartCountersIntegrationTest < Wurk::Test::UnitCase
  parallelize_me!

  SHUTDOWN_TIMEOUT = 1
  POLL_INTERVAL = 0.1

  def setup
    super
    @queue_name = "restartctr-#{::Process.pid}-#{object_id}-q"
    @port = free_port
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: Wurk::Test.redis_url }
    @config[:timeout] = SHUTDOWN_TIMEOUT
    @config.health_check(port: @port, bind: '127.0.0.1')
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_a_killed_child_counts_as_a_crash_on_the_replacements_metrics
    with_swarm do |swarm, original|
      assert_equal 0, wait_for(30) { restarts('crash') }, 'the first child never served /metrics'

      ::Process.kill('KILL', original)
      replacement = wait_for(30) { (swarm.children.keys - [original]).first }

      assert replacement, "killed child #{original} was never respawned"
      assert_equal 1, wait_for(30) { (value = restarts('crash'))&.positive? && value },
                   'the replacement must report the crash its parent counted'
      assert_equal 0, restarts('rolling')
    end
  end

  private

  def with_swarm
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.flat(count: 1, queues: [@queue_name], concurrency: 1),
                            config: @config, shutdown_timeout: SHUTDOWN_TIMEOUT)
    original = swarm.boot(install_signals: false).first
    supervisor = Thread.new { swarm.supervise }
    yield swarm, original
  ensure
    begin
      swarm&.shutdown(timeout: SHUTDOWN_TIMEOUT)
    rescue StandardError
      nil
    end
    stop_supervisor_thread(supervisor, 15) if supervisor
  end

  # nil until a child answers /metrics.
  def restarts(reason)
    body = Net::HTTP.get(URI("http://127.0.0.1:#{@port}/metrics"))
    body[/^wurk_swarm_child_restarts_total\{reason="#{reason}"\} (\d+)$/, 1]&.to_i
  rescue SystemCallError, IOError, Net::ReadTimeout
    nil
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  def wait_for(timeout)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
    loop do
      value = yield
      return value if value
      return nil if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

      sleep POLL_INTERVAL
    end
  end
end
