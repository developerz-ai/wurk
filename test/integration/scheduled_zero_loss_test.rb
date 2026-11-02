# frozen_string_literal: true

require_relative '../test_helper'
require 'socket'
require 'tmpdir'

# The default scheduler against a private redis-server, the only way to run
# these without touching a Redis other test workers share: `maxmemory` and
# DEBUG SLEEP are server-wide. Skips where no redis-server binary is installed.
class ScheduledZeroLossTest < Wurk::Test::UnitCase
  parallelize_me!

  LEASE = 0.2
  QUEUE = 'zero-loss'

  def setup
    super
    @binary = binary || binary_missing
    @port = free_port
    @dir = Dir.mktmpdir('wurk-zero-loss')
    @server = spawn(@binary, '--port', @port.to_s, '--dir', @dir, '--save', '', '--enable-debug-command', 'yes',
                    %i[out err] => File::NULL)
    @admin = RedisClient.config(url: url, timeout: 10).new_client
    wait_until('redis-server to answer') { ping? }
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: url, read_timeout: 0.2 }
    @config[:scheduled_claim_lease] = LEASE
  end

  def teardown
    @config&.reset_redis_pools!
    @admin&.close
    if @server
      Process.kill('KILL', @server)
      Process.wait(@server)
    end
    FileUtils.remove_entry(@dir) if @dir
  ensure
    super
  end

  # Past maxmemory every write the promotion needs is refused: the claim, the
  # push, and any write-back. Nothing may come off the set for good.
  def test_a_store_out_of_memory_loses_no_due_job
    jobs = seed(25)
    @admin.call('CONFIG', 'SET', 'maxmemory', '1')
    enq = Wurk::Scheduled::Enq.new(@config)
    @config.error_handlers.clear

    enq.enqueue_jobs(['schedule'])
    @admin.call('CONFIG', 'SET', 'maxmemory', '0')
    drain(enq)

    assert_equal jobs, queued_jids.uniq.sort
  end

  # The socket gives up on a pop the server still applies, which is what a lost
  # reply looks like. redis-client re-sends it; a destructive pop lost the first
  # job with its reply, without raising anything.
  def test_a_stall_past_the_read_timeout_loses_no_due_job
    jobs = seed(400)
    enq = Wurk::Scheduled::Enq.new(@config)
    @config.error_handlers.clear
    stalls = Array.new(3) do |i|
      Thread.new do
        sleep(i * 0.25)
        stall_client = RedisClient.config(url: url, timeout: 5).new_client
        stall_client.call('DEBUG', 'SLEEP', '0.4')
      ensure
        stall_client&.close
      end
    end

    drain(enq)
    stalls.each(&:join)
    drain(enq)

    assert_equal jobs, queued_jids.uniq.sort
  end

  private

  def binary_missing
    flunk 'redis-server is required in this job' if ENV['WURK_REQUIRE_REDIS_SERVER']

    skip 'no redis-server binary on PATH'
  end

  def binary
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, 'redis-server') }
       .find { |path| File.executable?(path) }
  end

  def url = "redis://127.0.0.1:#{@port}/0"

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  def ping?
    @admin.call('PING') == 'PONG'
  rescue RedisClient::Error
    false
  end

  def seed(count)
    at = Time.now.to_f - 60
    jids = Array.new(count) { |i| format('%024d', i) }
    @admin.pipelined do |pipe|
      jids.each_with_index do |jid, i|
        job = { 'class' => 'Worker', 'args' => [i], 'jid' => jid, 'queue' => QUEUE, 'retry' => true }
        pipe.call('ZADD', 'schedule', (at + (i * 0.001)).to_s, Wurk.dump_json(job))
      end
    end
    jids.sort
  end

  # Repeated polls until the set empties: a member a failure left under its lease
  # comes due again by itself.
  def drain(enq)
    wait_until('the schedule set to drain') do
      enq.enqueue_jobs(['schedule'])
      @admin.call('ZCARD', 'schedule').zero?
    end
  end

  def queued_jids
    @admin.call('LRANGE', "queue:#{QUEUE}", 0, -1).map { |raw| JSON.parse(raw)['jid'] }
  end

  def wait_until(what, timeout: 30)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
  end
end
