# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'socket'
require 'tmpdir'

# A Redis actually at `maxmemory` under `noeviction`. Filling one is a server-wide
# act, so this runs its own redis-server rather than touching the suite's.
class LeaderMaxmemoryTest < Wurk::Test::UnitCase
  def setup
    super
    skip 'needs a redis-server binary' unless system('command -v redis-server > /dev/null 2>&1')

    @dir = Dir.mktmpdir('wurk-leader-oom')
    @port = free_port
    @server = Process.spawn('redis-server', '--port', @port.to_s, '--bind', '127.0.0.1', '--save', '', '--dir', @dir,
                            '--maxmemory-policy', 'noeviction', out: IO::NULL, err: IO::NULL)
    @direct = RedisClient.config(url: "redis://127.0.0.1:#{@port}/0", timeout: 5).new_client
    wait_until_up
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: "redis://127.0.0.1:#{@port}/0" }
  end

  def teardown
    @config&.reset_redis_pools!
    @direct&.close
    if @server
      Process.kill('KILL', @server)
      Process.wait(@server)
    end
    FileUtils.rm_rf(@dir) if @dir
  ensure
    super
  end

  # A refused renewal lapses the lease, and with it every leader-gated consumer,
  # for as long as Redis stays full.
  def test_a_leader_keeps_its_lease_past_maxmemory
    leader = Wurk::Leader.new(config: @config, ttl: 30)
    leader.acquire
    @direct.call('EXPIRE', Wurk::Leader::DEFAULT_KEY, 5)
    fill!
    assert_raises(RedisClient::OutOfMemoryError) { @direct.call('LPUSH', 'proof', 'x') }

    assert leader.acquire
    assert_predicate leader, :leader?
    assert_operator @direct.call('TTL', Wurk::Leader::DEFAULT_KEY), :>, 5, 'the renewal landed'
  end

  def test_a_lease_can_be_won_past_maxmemory
    fill!
    leader = Wurk::Leader.new(config: @config)

    assert leader.acquire
    assert_equal leader.owner, @direct.call('GET', Wurk::Leader::DEFAULT_KEY)
    assert_equal 1, leader.token
  end

  def test_a_server_refusing_the_script_raises_the_original_refusal
    leader = Wurk::Leader.new(config: @config)
    refusing = Object.new
    refusing.define_singleton_method(:call) do |*args|
      raise RedisClient::CommandError, "ERR unexpected symbol near '#'" if args.first == 'EVAL'

      raise RedisClient::OutOfMemoryError, 'OOM original'
    end

    assert_raises(RedisClient::OutOfMemoryError) { leader.send(:next_token, refusing) }
  end

  def test_a_dropped_connection_is_not_mistaken_for_an_unsupported_server
    leader = Wurk::Leader.new(config: @config)
    gone = Object.new
    gone.define_singleton_method(:call) do |*args|
      raise RedisClient::ConnectionError, 'gone' if args.first == 'EVAL'

      raise RedisClient::OutOfMemoryError, 'OOM original'
    end

    assert_raises(RedisClient::ConnectionError) { leader.send(:next_token, gone) }
  end

  private

  def fill!
    used = @direct.call('INFO', 'memory')[/used_memory:(\d+)/, 1].to_i
    @direct.call('CONFIG', 'SET', 'maxmemory', (used - 1024).to_s)
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  def wait_until_up
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 10
    begin
      @direct.call('PING')
    rescue RedisClient::Error
      raise if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
      retry
    end
  end
end
