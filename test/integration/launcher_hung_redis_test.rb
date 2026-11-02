# frozen_string_literal: true

require_relative '../test_helper'
require 'socket'

# An embedded host outlives `Launcher#stop`, so a stop that gave up on a hung
# Redis must not leave anything of the launcher behind. A real Redis behind a
# forwarder that can stop answering, the shape a hung server has to a client.
class LauncherHungRedisTest < Wurk::Test::UnitCase
  # Forwards bytes to Redis until frozen; while frozen, a client's reads hang.
  class FreezableProxy
    attr_reader :port

    def initialize(target_port)
      @target_port = target_port
      @server = TCPServer.new('127.0.0.1', 0)
      @port = @server.addr[1]
      @frozen = false
      @sockets = []
      @thread = Thread.new { accept_loop }
    end

    def freeze! = @frozen = true
    def thaw! = @frozen = false

    def close
      @thread.kill
      @server.close
      @sockets.each { |socket| socket.close unless socket.closed? }
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        upstream = TCPSocket.new('127.0.0.1', @target_port)
        @sockets.push(client, upstream)
        Thread.new { relay(client, upstream) }
        Thread.new { relay(upstream, client) }
      end
    end

    def relay(source, sink)
      loop do
        sleep 0.02 while @frozen
        sink.write(source.readpartial(4096))
      end
    rescue IOError, SystemCallError
      [source, sink].each { |socket| socket.close unless socket.closed? }
    end
  end

  def setup
    super
    target = URI(Wurk::Test.redis_url)
    @db = target.path
    @proxy = FreezableProxy.new(target.port)
    @direct = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @threads_before = Thread.list
    @launcher = build_launcher
    @launcher.run
  end

  def teardown
    @proxy.thaw!
    @replacement&.send(:clear_heartbeat)
    @config&.reset_redis_pools!
    @replacement_config&.reset_redis_pools!
    @direct&.close
    @proxy.close
  ensure
    super
  end

  def test_nothing_of_the_launcher_survives_a_stop_that_gave_up
    threads = (Thread.list - @threads_before).select(&:name)

    refute_empty threads, 'precondition: the loops are running'
    @proxy.freeze!
    elapsed = timed { @launcher.stop }

    assert_operator elapsed, :<, Wurk::Launcher::TEARDOWN_GRACE + Wurk::TimerLoop::JOIN_TIMEOUT + 2
    assert_empty threads.select(&:alive?), 'a loop outlived the stop into the embedded host'
  end

  def test_a_stop_that_gave_up_cannot_clear_a_replacements_heartbeat
    @proxy.freeze!
    @launcher.stop

    @replacement_config = fresh_config(Wurk::Test.redis_url)
    @replacement = Wurk::Launcher.new(@replacement_config, embedded: true)
    @replacement.heartbeat
    identity = @replacement.identity
    # Redis is answering again: an abandoned teardown would now get through.
    @proxy.thaw!
    deadline = monotonic + 4
    while monotonic < deadline
      assert_equal 1, @direct.call('SISMEMBER', Wurk::Keys::PROCESSES, identity),
                   'the old teardown cleared the replacement'
      sleep 0.1
    end
  end

  private

  def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

  def timed
    started = monotonic
    yield
    monotonic - started
  end

  def fresh_config(url)
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config.redis = { url: url, connect_timeout: 1, read_timeout: 1, write_timeout: 1 }
    config[:timeout] = 0
    config.queues = %w[hung-redis-test]
    config.concurrency = 1
    config
  end

  def build_launcher
    @config = fresh_config("redis://127.0.0.1:#{@proxy.port}#{@db}")
    Wurk::Launcher.new(@config, embedded: true)
  end
end
