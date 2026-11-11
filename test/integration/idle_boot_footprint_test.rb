# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'

# Pins what an idle worker holds: every thread by name and every Redis
# connection, read from a real exe/wurk against real Redis. A thread or socket
# that appears here without a job or a configured feature asking for it is the
# regression this guards (plan 101, 06-perf-hot-path-boot L7).
#
# Absent on purpose: the bounded-job watchdog (spawned by the first bounded
# job), the History snapshotter (`config.retain_history`), the health listener
# (`config.health_check` / WURK_HEALTH_PORT) and any statsd socket (the client
# is host-supplied). The cron poller and the leader run with no periodic job
# configured, because the leader enqueues every process's registered loops and
# drives the always-on metrics rollups.
class IdleBootFootprintTest < Wurk::Test::UnitCase
  CONCURRENCY = 3
  SETTLE_TIMEOUT = 30.0
  POLL_INTERVAL = 0.1
  SHUTDOWN_TIMEOUT = 3

  IDLE_THREADS = {
    'main' => 1,
    'default/processor' => CONCURRENCY,
    'heartbeat' => 1,
    'scheduler' => 1,
    'wurk-leader' => 1,
    'wurk-reaper' => 1,
    'cron-poller' => 1,
    'metrics-rollup' => 1,
    'queue-metrics' => 1,
    'queue-consumers' => 1,
    'metrics-flush' => 1
  }.freeze

  def setup
    super
    @ns = "idlefp-#{::Process.pid}-#{object_id}"
    @threads_key = "#{@ns}:threads"
    @boot_file = ::File.join(::Dir.tmpdir, "#{@ns}-boot.rb")
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer&.call('DEL', @threads_key)
    @observer&.close
    ::FileUtils.rm_f(@boot_file)
  ensure
    super
  end

  def test_idle_worker_threads_and_connections
    write_boot_file
    pid = spawn_worker
    begin
      threads = wait_for_settled_threads

      assert_equal IDLE_THREADS, threads, 'idle worker threads by name'

      conns = wait_for_parked_fetch_connections
      fetch = conns.count { |c| parked?(c) }

      assert_equal CONCURRENCY, fetch, "one fetch socket per processor, parked in BLMOVE: #{conns}"
      # The main pool holds what the background loops (heartbeat, poller,
      # leader, reaper, cron, rollups) keep warm when their checkouts overlap:
      # 4 at `-c 3`, measured with the empty-poll LMOVE on either pool, so it is
      # not the fetcher's.
      assert_operator conns.size - fetch, :<=, CONCURRENCY + 1, "main-pool sockets: #{conns}"
    ensure
      stop(pid)
    end
  end

  # Building a capsule's pools opens no socket: the first checkout does.
  def test_prepared_capsule_pools_connect_on_first_checkout
    config = Wurk::Configuration.new
    config.redis = { url: Wurk::Test.redis_url, id: @ns }
    capsule = Wurk::Capsule.new('default', config)
    capsule.concurrency = CONCURRENCY
    capsule.prepare!

    assert_empty worker_connections, 'prepare! must not connect either pool'

    capsule.fetch_redis_pool.with { |conn| conn.call('PING') }

    assert_equal 1, worker_connections.size
  ensure
    capsule&.reset_redis_pools!
  end

  private

  # A `:startup` hook records Thread.list on a loop; the recorder excludes
  # itself and names the main thread, which Ruby leaves unnamed.
  def write_boot_file
    ::File.write(@boot_file, <<~RUBY)
      require 'redis-client'
      url = ENV.fetch('REDIS_URL')

      Wurk.configure_server do |config|
        config.redis = { url: url, id: #{@ns.inspect} }
        config.on(:startup) do
          Thread.new do
            c = RedisClient.config(url: url).new_client
            loop do
              names = (Thread.list - [Thread.current]).map { |t| t == Thread.main ? 'main' : t.name.to_s }
              c.call('SET', #{@threads_key.inspect}, names.sort.join(','), 'EX', 60)
              sleep 0.2
            rescue StandardError
              # A dropped connection must not take the settle signal with it:
              # the worker keeps running, so the recorder reconnects and
              # writes the thread set again.
              begin
                c.close
              rescue StandardError
                nil
              end
              c = RedisClient.config(url: url).new_client
              sleep 0.2
            end
          end
        end
      end
    RUBY
  end

  def spawn_worker
    exe = ::File.expand_path('../../exe/wurk', __dir__)
    ::Process.spawn(
      { 'REDIS_URL' => Wurk::Test.redis_url, 'COVERAGE' => nil },
      'bundle', 'exec', exe,
      '-r', @boot_file, '-q', "#{@ns}-q", '-c', CONCURRENCY.to_s, '-e', 'production',
      '-t', SHUTDOWN_TIMEOUT.to_s,
      chdir: ::File.expand_path('../..', __dir__), out: ::IO::NULL, err: ::IO::NULL
    )
  end

  # Boot is settled once the worker reports the same thread set twice in a row;
  # the one-shot boot-reclaim thread may still be finishing. The wait is best
  # effort: the assertion above is what judges the set, so a worker whose set
  # never repeats is reported by the diff, not by a timeout.
  def wait_for_settled_threads
    deadline = monotonic_now + SETTLE_TIMEOUT
    previous = nil
    while monotonic_now < deadline
      current = @observer.call('GET', @threads_key)&.split(',')&.tally
      return current if current && current == previous

      previous = current
      sleep POLL_INTERVAL * 3
    end

    previous || flunk('idle worker never reported its threads')
  end

  # A processor parks in BLMOVE and polls again two seconds later, so an
  # instant where one of them sits between polls is normal, and on a loaded
  # server that window is wide. The parked sockets are therefore sampled on
  # their own, and the snapshot the assertions read is one where every
  # processor is parked - not one where two independent samples happen to
  # agree.
  def wait_for_parked_fetch_connections
    deadline = monotonic_now + SETTLE_TIMEOUT
    conns = worker_connections
    while conns.count { |c| parked?(c) } != CONCURRENCY && monotonic_now < deadline
      sleep POLL_INTERVAL * 3
      conns = worker_connections
    end
    conns
  end

  # Blocked in BLMOVE, the only blocking command a worker sends. The `b` flag,
  # not `cmd`: Dragonfly's CLIENT LIST has no `cmd` field.
  def parked?(conn)
    conn['flags'].to_s.include?('b')
  end

  def worker_connections
    @observer.call('CLIENT', 'LIST').lines.filter_map do |line|
      fields = line.split.to_h { |kv| kv.split('=', 2) }
      fields if fields['name'] == @ns
    end
  end

  def stop(pid)
    ::Process.kill('TERM', pid)
    deadline = monotonic_now + SHUTDOWN_TIMEOUT + 10
    while monotonic_now < deadline
      return if ::Process.wait(pid, ::Process::WNOHANG)

      sleep POLL_INTERVAL
    end
    ::Process.kill('KILL', pid)
    ::Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
