# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'socket'
require 'tmpdir'

class MaxmemoryDrainJob
  include Wurk::Job

  RAN = Queue.new

  def perform(tag)
    RAN << tag
  end
end

class MaxmemoryFailingJob
  include Wurk::Job

  sidekiq_retry_in { 3600 }

  RAN = Queue.new

  def perform(tag)
    RAN << tag
    raise 'fails while Redis is full'
  end
end

# A Redis actually at `maxmemory` under `noeviction`. Filling one is a server-wide
# act, so this runs its own redis-server rather than touching the suite's.
class MaxmemoryDrainTest < Wurk::Test::UnitCase
  def setup
    super
    skip 'needs a redis-server binary' unless system('command -v redis-server > /dev/null 2>&1')

    @dir = Dir.mktmpdir('wurk-oom')
    @port = free_port
    @server = Process.spawn('redis-server', '--port', @port.to_s, '--bind', '127.0.0.1', '--save', '', '--dir', @dir,
                            '--maxmemory-policy', 'noeviction', out: IO::NULL, err: IO::NULL)
    @url = "redis://127.0.0.1:#{@port}/0"
    @direct = RedisClient.config(url: @url, timeout: 5).new_client
    wait_until(timeout: 10) { ping? }
    @queue_name = 'oom'
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: @url }
    @capsule = @config.default_capsule
    @capsule.queues = [@queue_name]
    @capsule.concurrency = 2
    @config.fetch_poll_interval = 0.1
    @capsule.prepare!
  end

  def teardown
    @manager&.stop(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1)
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

  def test_a_full_redis_drains_with_the_limit_still_in_place
    20.times { |i| push('MaxmemoryDrainJob', i) }
    fill!
    assert_raises(RedisClient::OutOfMemoryError) { @direct.call('LPUSH', 'queue:proof', 'x') }

    start_worker

    ran = Array.new(20) { MaxmemoryDrainJob::RAN.pop(timeout: 15) }

    assert_equal (0...20).to_a, ran.compact.sort
    assert_operator @direct.call('CONFIG', 'GET', 'maxmemory').to_a.flatten.last.to_i, :>, 0
    wait_until { @direct.call('KEYS', 'queue:oom|*').empty? }

    assert_equal 0, @direct.call('LLEN', 'queue:oom')
  end

  def test_a_job_failing_at_maxmemory_books_its_retry_rather_than_stranding
    push('MaxmemoryFailingJob', 'f', retries: true)
    fill!

    start_worker

    assert_equal 'f', MaxmemoryFailingJob::RAN.pop(timeout: 15)
    wait_until { @direct.call('ZCARD', 'retry') == 1 }
    wait_until { @direct.call('KEYS', 'queue:oom|*').empty? }
  end

  # A SIGKILLed worker's jobs have to come back even with Redis full, or a dead
  # process's work waits on the memory the live ones are trying to free.
  def test_the_reaper_reclaims_at_maxmemory
    list = "queue:oom|other-host.example|999999|#{SecureRandom.hex(6)}|0"
    @direct.call('RPUSH', list, 'orphan')
    fill!
    reaper = Wurk::Fetcher::Reaper.new(@config, grace: 0)
    @capsule.queues = [@queue_name]

    assert_equal 1, reaper.reclaim!
    assert_equal ['orphan'], @direct.call('LRANGE', 'queue:oom', 0, -1)
  end

  # SET NX is refused too, and a sweep lock nobody can take means no periodic
  # sweep at all. The poison counter's INCR is the other refusal: raising past
  # the first job left one job moved per pass.
  def test_a_periodic_sweep_moves_every_orphan_at_maxmemory
    lists = Array.new(3) { "queue:oom|other-host.example|99999#{_1}|#{SecureRandom.hex(6)}|0" }
    lists.each { |list| @direct.call('RPUSH', list, job_payload, job_payload, job_payload) }
    fill!
    reaper = Wurk::Fetcher::Reaper.new(@config, grace: 0)

    with_global_redis_on_this_server { assert_equal 9, reaper.reap }

    assert_equal 9, @direct.call('LLEN', 'queue:oom')
  end

  def test_a_requeue_hands_the_job_back_on_a_cold_script_cache
    @direct.call('RPUSH', 'queue:oom|h|1|n|0', 'held')

    Wurk::Fetcher::Reliable::UnitOfWork.new(queue: 'queue:oom', queue_name: 'oom', private_queue: 'queue:oom|h|1|n|0',
                                            job: 'held', config: @capsule).requeue

    assert_equal ['held'], @direct.call('LRANGE', 'queue:oom', 0, -1)
    assert_equal 0, @direct.call('LLEN', 'queue:oom|h|1|n|0')
  end

  # A hard shutdown is what frees a full Redis's workers: their jobs must get back.
  def test_a_bulk_requeue_gets_past_maxmemory
    fetcher = Wurk::Fetcher::Reliable.new(@capsule)
    list = Wurk::Fetcher::Reliable.private_queue_name('queue:oom')
    @direct.call('RPUSH', list, 'a', 'b')
    units = %w[a b].map do |job|
      Wurk::Fetcher::Reliable::UnitOfWork.new(queue: 'queue:oom', queue_name: 'oom', private_queue: list,
                                              job: job, config: @capsule)
    end
    fill!

    fetcher.bulk_requeue(units)

    assert_equal %w[a b], @direct.call('LRANGE', 'queue:oom', 0, -1).sort
    assert_equal 0, @direct.call('LLEN', list)
  end

  def test_self_reconcile_puts_a_payload_back_past_maxmemory
    list = Wurk::Fetcher::Reliable.private_queue_name('queue:oom')
    @direct.call('RPUSH', list, 'stranded')
    sweeper = Wurk::Fetcher::SelfReconcile.new(@config, confirm: 0)
    fill!

    sweeper.sweep

    assert_equal 1, sweeper.sweep
    assert_equal ['stranded'], @direct.call('LRANGE', 'queue:oom', 0, -1)
  end

  # ZREM is not `denyoom`, the push and the ZADD putting the entry back are.
  def test_a_dashboard_retry_refused_at_maxmemory_stays_in_its_set
    entry_json = Wurk.dump_json('class' => 'X', 'args' => [], 'jid' => SecureRandom.hex(12), 'queue' => 'oom')
    @direct.call('ZADD', 'retry', 100, entry_json)
    fill!

    with_global_redis_on_this_server do
      entry = Wurk::SortedEntry.new(Wurk::RetrySet.new, 100, entry_json)
      assert_raises(RedisClient::OutOfMemoryError) do
        entry.send(:remove_job) { |_| @direct.call('LPUSH', 'queue:oom', entry_json) }
      end
    end

    assert_equal [entry_json], @direct.call('ZRANGE', 'retry', 0, -1)
  end

  private

  def job_payload
    Wurk.dump_json('class' => 'X', 'args' => [], 'jid' => SecureRandom.hex(12), 'queue' => 'oom')
  end

  def with_global_redis_on_this_server
    config = @config
    original = Wurk.method(:redis)
    Wurk.define_singleton_method(:redis) { |**, &block| config.redis(&block) }
    yield
  ensure
    Wurk.define_singleton_method(:redis, original)
  end

  def fill!
    used = @direct.call('INFO', 'memory')[/used_memory:(\d+)/, 1].to_i
    @direct.call('CONFIG', 'SET', 'maxmemory', (used - 1024).to_s)
  end

  def push(klass, tag, retries: false)
    @direct.call('LPUSH', 'queue:oom',
                 Wurk.dump_json('class' => klass, 'args' => [tag], 'jid' => SecureRandom.hex(12),
                                'queue' => 'oom', 'retry' => retries))
  end

  def start_worker
    @manager = Wurk::Manager.new(@capsule)
    @manager.start
  end

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  def ping?
    @direct.call('PING') == 'PONG'
  rescue RedisClient::Error
    false
  end

  def wait_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    assert yield, 'condition never held'
  end
end
