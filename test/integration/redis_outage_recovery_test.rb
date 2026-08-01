# frozen_string_literal: true

require_relative '../test_helper'
require 'socket'
require 'uri'

# Top-level (not nested) so Processor#build_instance's `Object.const_get`
# resolves it the same way every other sentinel worker in this suite does.
# Records its own execution directly against real Redis (bypassing the
# BlipProxy entirely) so the recording itself can never be affected by the
# very outage the test is injecting.
class RedisOutageRecoverySentinelWorker
  include Wurk::Job

  def perform(redis_url, exec_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('RPUSH', exec_key, jid)
  ensure
    client&.close
  end
end

# Production incident #101 DoD: a transient Redis blip must self-heal through
# RedisPool's retry+backoff (Wurk::RedisPool#run) with zero job failures and
# zero duplicate executions, with no process restart, and the main pool must
# sit fully available again once fetching goes idle (the dedicated fetch pool
# is what makes that last part possible — see Capsule#fetch_redis_pool).
#
# No mock: every job push, fetch, ack and assertion round-trips through a
# real Redis server (Wurk::Test.redis_url). The "blip" is a real TCP outage
# injected by BlipProxy, a transparent relay this test sits the pool's Redis
# connection behind — CLIENT PAUSE / DEBUG SLEEP would work too, but freeze
# the *entire* shared instance for the whole poll timeout (see the
# ClientOutageTest / LivenessProbeTest comments: minitest-parallel_fork runs
# every test class against the *same* Redis process, just different logical
# DBs, so a global pause races every sibling test). The proxy confines the
# blip to this test's own connections.
class RedisOutageRecoveryTest < Wurk::Test::UnitCase
  parallelize_me!

  JOB_COUNT      = 6
  CONCURRENCY    = 3
  BLIP_SECONDS   = 2.5 # within CONN_MAX_ATTEMPTS' backoff budget (~3.2s worst case)
  POLL_TIMEOUT   = 20.0
  POLL_INTERVAL  = 0.1

  def setup
    super
    @ns = "outage-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @exec_key = "#{@ns}-exec"
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @proxy = BlipProxy.new(Wurk::Test.redis_url)
    @config = build_config
    @capsule = build_capsule
    @manager = Wurk::Manager.new(@capsule)
  end

  def teardown
    stop_manager
    @proxy&.stop!
    cleanup_keys
    @config&.reset_redis_pools!
    @observer&.close
  ensure
    super
  end

  # rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions
  def test_blip_self_heals_with_no_failures_no_duplicates_and_idle_holds_no_main_pool_conns
    jids = enqueue_jobs(JOB_COUNT)
    @manager.start

    assert wait_until? { executed_count >= 1 }, 'no job executed before the blip — pipeline never started'

    @proxy.blip!(BLIP_SECONDS)

    assert wait_until?(timeout: POLL_TIMEOUT) { executed_count == JOB_COUNT },
           "expected #{JOB_COUNT} executions after the blip, saw #{executed_count} within #{POLL_TIMEOUT}s"

    executed = @observer.call('LRANGE', @exec_key, 0, -1)

    assert_equal JOB_COUNT, executed.size, 'a job was lost across the blip'
    assert_equal JOB_COUNT, executed.uniq.size, 'a job ran more than once across the blip'
    assert_equal jids.sort, executed.sort, 'executed jids must exactly match the enqueued jids'

    assert_equal 0, @observer.call('ZCARD', Wurk::Keys::RETRY).to_i, 'no job should have failed into the retry set'
    assert_equal 0, @observer.call('ZCARD', Wurk::Keys::DEAD).to_i, 'no job should have failed into the dead set'
    assert_equal 0, @observer.call('LLEN', "queue:#{@queue_name}").to_i, 'public queue must fully drain'

    # The ack (LREM) runs in Processor#process's ensure, *after* perform
    # returns, and goes through the blipped pool's retry+backoff — while the
    # sentinel records its execution over a direct connection that bypasses the
    # proxy. So "all jobs executed" strictly precedes "all jobs acked"; poll for
    # the drain rather than sampling it the instant the last job runs.
    assert wait_until?(timeout: POLL_TIMEOUT) { private_queue_depth.zero? },
           "private list must fully drain (every job acked), still holding #{private_queue_depth}"

    refute_predicate @manager, :stopped?, 'the manager must self-heal in place — no restart'

    quiesce!

    assert_equal @capsule.redis_pool.size, @capsule.redis_pool.available,
                 'idle worker must hold zero main-pool connections once fetching goes idle'
    assert_equal @capsule.fetch_redis_pool.size, @capsule.fetch_redis_pool.available,
                 'idle worker must hold zero fetch-pool connections once fetching goes idle'
  end
  # rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions

  private

  def build_config
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config.redis = { url: @proxy.url }
    config[:fetch_poll_interval] = 0.2
    config
  end

  def build_capsule
    cap = @config.default_capsule
    cap.queues = [@queue_name]
    cap.concurrency = CONCURRENCY
    cap.prepare!
  end

  def stop_manager
    return unless @manager

    workers = @manager.workers.dup
    @manager.quiet
    workers.each(&:kill)
  end

  def enqueue_jobs(count)
    client = Wurk::Client.new(pool: @capsule.redis_pool, config: @config)
    count.times.map do
      client.push('class' => RedisOutageRecoverySentinelWorker.name,
                  'args' => [Wurk::Test.redis_url, @exec_key],
                  'queue' => @queue_name)
    end
  end

  def executed_count
    @observer.call('LLEN', @exec_key).to_i
  end

  # Stops fetching (Manager#quiet, no replacement processors spawned) and
  # blocks until every processor thread has actually exited its run loop —
  # not just requested to — so the pool-availability assertion below can't
  # race a thread that's mid-checkout.
  def quiesce!
    workers = @manager.workers.dup
    @manager.quiet
    workers.each { |w| w.thread&.join(5) }
  end

  def private_queue_key
    Wurk::Fetcher::Reliable.private_queue_name("queue:#{@queue_name}")
  end

  def private_queue_depth
    @observer.call('LLEN', private_queue_key).to_i
  end

  def wait_until?(timeout: 5.0)
    deadline = monotonic_now + timeout
    while monotonic_now < deadline
      return true if yield

      sleep POLL_INTERVAL
    end
    false
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def cleanup_keys
    return unless @observer

    @observer.call('DEL', @exec_key, "queue:#{@queue_name}", private_queue_key)
    @observer.call('SREM', 'queues', @queue_name)
  rescue StandardError
    nil
  end

  # Transparent TCP relay sitting in front of the real (shared) test Redis
  # instance. `blip!` drops every currently-relayed byte stream and refuses
  # new connections for the given window, then restores plain pass-through —
  # a real network blip confined to whichever pool points at this proxy's
  # `#url`, so sibling parallel test workers on the same shared Redis process
  # are never disturbed.
  class BlipProxy
    def initialize(upstream_url)
      uri = URI.parse(upstream_url)
      @upstream_host = uri.host
      @upstream_port = uri.port
      @db = uri.path.delete_prefix('/')
      @server = TCPServer.new('127.0.0.1', 0)
      @port = @server.addr(false)[1]
      @outage = false
      @stopped = false
      @mutex = ::Mutex.new
      @sockets = []
      @pump_threads = []
      @accept_thread = Thread.new { accept_loop }
    end

    def url
      "redis://127.0.0.1:#{@port}/#{@db}"
    end

    def blip!(seconds)
      @mutex.synchronize do
        @outage = true
        drop_tracked_sockets
      end
      sleep seconds
      @mutex.synchronize { @outage = false }
    end

    def stop!
      @accept_thread.kill
      @accept_thread.join(1)
      @server.close
    rescue IOError, Errno::EBADF
      nil
    ensure
      # Flip `@stopped` in the same critical section that takes the snapshot, so
      # a relay racing this shutdown either lands in the snapshot or is refused
      # outright — never registers into a list nobody will drain again.
      sockets, pumps = @mutex.synchronize do
        @stopped = true
        snapshot = [@sockets.dup, @pump_threads.dup]
        @sockets.clear
        @pump_threads.clear
        snapshot
      end
      # Outside the mutex: a killed pump's `ensure` calls untrack, which wants
      # the same mutex, so holding it here would make every join burn its
      # full 1s timeout and then leave the thread alive anyway.
      sockets.each { |s| close_quietly(s) }
      pumps.each(&:kill)
      pumps.each { |t| t.join(1) }
    end

    private

    def accept_loop
      loop do
        client = @server.accept
        if outage?
          close_quietly(client)
          next
        end
        relay(client)
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def outage?
      @mutex.synchronize { @outage }
    end

    def relay(client)
      return close_quietly(client) unless track(client)

      upstream = TCPSocket.new(@upstream_host, @upstream_port)
      return close_quietly(upstream) unless track(upstream)

      pump(client, upstream)
      pump(upstream, client)
    end

    def track(sock)
      @mutex.synchronize do
        return false if @stopped

        @sockets.push(sock)
        true
      end
    end

    # Spawn under the mutex so creation and registration are one step: a thread
    # created after stop! took its snapshot would never be killed or joined.
    def pump(from, dest)
      @mutex.synchronize do
        return nil if @stopped

        thread = Thread.new do
          IO.copy_stream(from, dest)
        rescue StandardError
          nil
        ensure
          untrack(from)
          untrack(dest)
        end
        @pump_threads.push(thread)
        thread
      end
    end

    def untrack(sock)
      @mutex.synchronize { @sockets.delete(sock) }
      close_quietly(sock)
    end

    def drop_tracked_sockets
      @sockets.each { |s| close_quietly(s) }
      @sockets.clear
    end

    def close_quietly(sock)
      sock.close
    rescue StandardError
      nil
    end
  end
end
