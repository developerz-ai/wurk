# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'socket'
require 'tmpdir'

# A Redis actually at `maxmemory` under `noeviction`: filling one is server-wide,
# so this runs its own redis-server rather than touching the suite's.
class HeartbeatAtMaxmemoryTest < Wurk::Test::UnitCase
  IDENTITY = 'oom-host:1:nonce'

  def setup
    super
    skip 'needs a redis-server binary' unless system('command -v redis-server > /dev/null 2>&1')

    @dir = Dir.mktmpdir('wurk-oom-beat')
    @port = free_port
    @server = Process.spawn('redis-server', '--port', @port.to_s, '--bind', '127.0.0.1', '--save', '', '--dir', @dir,
                            '--maxmemory-policy', 'noeviction', out: IO::NULL, err: IO::NULL)
    @direct = RedisClient.config(url: "redis://127.0.0.1:#{@port}/0", timeout: 5).new_client
    wait_for_server
    @errors = []
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: "redis://127.0.0.1:#{@port}/0" }
    @config.error_handlers.replace([->(ex, _ctx, _cfg = nil) { @errors << ex.class }])
    @heartbeat = Wurk::Heartbeat.new(identity: IDENTITY, config: @config, started_at: Time.now.to_f)
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

  def test_the_beat_keeps_moving_while_redis_is_full
    @heartbeat.beat!
    before = beat_value
    fill!

    assert_raises(RedisClient::OutOfMemoryError) { @direct.call('SET', 'precondition', 'x') }
    sleep 0.01 until Time.now.to_f > before
    @heartbeat.beat!

    assert_operator beat_value, :>, before
    assert_empty @errors
  end

  def test_a_process_whose_hash_lapsed_is_listed_again
    fill!
    @heartbeat.beat!

    assert_equal 1, @direct.call('SISMEMBER', Wurk::Keys::PROCESSES, IDENTITY)
    assert @direct.call('HGET', IDENTITY, 'info')
    assert_operator @direct.call('TTL', IDENTITY), :>, 0
    assert_empty @errors
  end

  def test_the_work_mirror_stays_accurate_while_redis_is_full
    with_work('old' => { 'queue' => 'q' }) { @heartbeat.beat! }
    fill!
    with_work('new' => { 'queue' => 'q' }) { @heartbeat.beat! }

    assert_equal ['new'], @direct.call('HKEYS', "#{IDENTITY}:work")
    assert_operator @direct.call('TTL', "#{IDENTITY}:work"), :>, 0
    assert_empty @errors
  end

  # Dragonfly, or anything else that refuses the script: the beat fails as it
  # always did, but the dashboard must not lose the job that is still running.
  def test_a_refused_rewrite_leaves_the_work_mirror_alone
    with_work('old' => { 'queue' => 'q' }) { @heartbeat.beat! }
    fill!
    def @heartbeat.beat_at_maxmemory(_conn, error, _work) = raise(error)
    with_work('new' => { 'queue' => 'q' }) { @heartbeat.beat! }

    assert_equal ['old'], @direct.call('HKEYS', "#{IDENTITY}:work")
    assert_equal [RedisClient::OutOfMemoryError], @errors
  end

  # A hold the beat stops refreshing lapses, and a global cap then over-admits.
  def test_global_concurrency_holds_are_refreshed_while_redis_is_full
    @direct.call('ZADD', 'queue_slot:capped', '1', 'holder')
    Wurk::QueueSlot::HELD.hold('holder', 'queue_slot:capped')
    fill!
    @heartbeat.beat!

    assert_operator @direct.call('ZSCORE', 'queue_slot:capped', 'holder').to_f, :>, Time.now.to_f
    assert_empty @errors
  ensure
    Wurk::QueueSlot::HELD.drop('holder', 'queue_slot:capped')
  end

  def test_a_server_refusing_the_script_reports_the_original_oom
    original = RedisClient::OutOfMemoryError.new('OOM')
    refusing = Object.new
    def refusing.call(*) = raise(RedisClient::CommandError, 'ERR unsupported shebang')

    raised = assert_raises(RedisClient::OutOfMemoryError) do
      @heartbeat.send(:beat_at_maxmemory, refusing, original)
    end

    assert_same original, raised
  end

  private

  def with_work(work)
    Wurk::Processor::WORK_STATE.clear
    work.each { |tid, hash| Wurk::Processor::WORK_STATE.set(tid, hash) }
    yield
  ensure
    Wurk::Processor::WORK_STATE.clear
  end

  def beat_value = @direct.call('HGET', IDENTITY, 'beat').to_f

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

  def wait_for_server
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    begin
      @direct.call('PING')
    rescue RedisClient::Error
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
      retry
    end
  end
end
