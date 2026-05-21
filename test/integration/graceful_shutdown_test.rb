# frozen_string_literal: true

require_relative '../test_helper'

# Top-level so the constant resolves identically in the forked
# subprocess (Object inherits via fork; lexically nested classes do not
# round-trip cleanly through Marshal/const_get).
class GracefulShutdownSentinelWorker
  include Wurk::Job

  # Reports its PID into `started_key` immediately, sleeps, then reports
  # into `done_key`. Tests assert that `done_key` is written even after
  # SIGTERM hits the parent mid-sleep.
  def perform(redis_url, started_key, done_key, sleep_seconds)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', started_key, ::Process.pid.to_s)
    client.call('EXPIRE', started_key, 60)
    sleep sleep_seconds
    client.call('SET', done_key, ::Process.pid.to_s)
    client.call('EXPIRE', done_key, 60)
  ensure
    client&.close
  end
end

# Real fork, real signal, real Redis. Boot a swarm in a subprocess with
# install_signals: true, enqueue an in-flight job, SIGTERM the parent,
# assert the job finishes within shutdown_timeout.
#
# Safe under the file-level parallel runner: the supervisor runs in a
# forked subprocess, and the test only waits on its specific PID
# (Process.wait(parent_pid, …)) — no global -1 reap that could steal a
# sibling test's child.
class GracefulShutdownTest < Wurk::Test::UnitCase
  parallelize_me!

  REDIS_URL = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
  POLL_TIMEOUT = 30.0
  POLL_INTERVAL = 0.1
  SHUTDOWN_TIMEOUT = 15

  def setup
    super
    @ns = "gshut-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @started_key = "#{@ns}-started"
    @done_key = "#{@ns}-done"
    @observer = RedisClient.config(url: REDIS_URL).new_client
  end

  def teardown
    cleanup_observer_keys
    @observer&.close
  ensure
    super
  end

  def test_sigterm_to_parent_lets_in_flight_job_drain # rubocop:disable Minitest/MultipleAssertions
    push_job(sleep_seconds: 2)
    parent_pid = fork_swarm_supervisor(count: 1)

    begin
      assert wait_for_key(@started_key), 'in-flight job never started within poll timeout'
      assert_nil @observer.call('GET', @done_key), 'job finished before we could SIGTERM (raise sleep_seconds)'

      ::Process.kill('TERM', parent_pid)

      assert wait_for_pid_exit(parent_pid, timeout: SHUTDOWN_TIMEOUT + 5),
             "supervisor pid #{parent_pid} did not exit within shutdown_timeout"
      assert @observer.call('GET', @done_key),
             'in-flight job did not finish — graceful drain should have let it complete'
    ensure
      reap_supervisor(parent_pid)
    end
  end

  private

  def push_job(sleep_seconds:)
    config = build_config
    client = Wurk::Client.new(pool: capsule_pool(config), config: config)
    client.push('class' => GracefulShutdownSentinelWorker.name,
                'args' => [REDIS_URL, @started_key, @done_key, sleep_seconds],
                'queue' => @queue_name)
  ensure
    config&.reset_redis_pools!
  end

  def build_config
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:timeout] = SHUTDOWN_TIMEOUT
    config
  end

  def capsule_pool(config)
    cap = config.default_capsule
    cap.queues = [@queue_name]
    cap.redis_pool
  end

  # Boots the swarm inside a subprocess so SIGTERM exercises the real
  # signal handler. install_signals: true is what we want to test.
  def fork_swarm_supervisor(count:)
    ::Process.fork do
      $stdout.reopen(IO::NULL)
      $stderr.reopen(IO::NULL)
      config = build_config
      topology = Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
      swarm = Wurk::Swarm.new(topology: topology, config: config, shutdown_timeout: SHUTDOWN_TIMEOUT)
      swarm.boot(install_signals: true)
      swarm.supervise
      exit 0
    end
  end

  def wait_for_key(key) # rubocop:disable Naming/PredicateMethod
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      return true if @observer.call('GET', key)

      sleep POLL_INTERVAL
    end
    false
  end

  def wait_for_pid_exit(pid, timeout:)
    deadline = monotonic_now + timeout
    while monotonic_now < deadline
      return true if ::Process.wait(pid, ::Process::WNOHANG)

      sleep POLL_INTERVAL
    end
    false
  rescue Errno::ECHILD
    true
  end

  def reap_supervisor(pid)
    return unless pid_alive?(pid)

    ::Process.kill('KILL', pid)
    begin
      ::Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def pid_alive?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def cleanup_observer_keys
    return unless @observer

    @observer.call('DEL', @started_key, @done_key, "queue:#{@queue_name}")
    cursor = '0'
    loop do
      cursor, keys = @observer.call('SCAN', cursor, 'MATCH', "queue:#{@queue_name}|*", 'COUNT', 100)
      @observer.call('DEL', *keys) unless keys.empty?
      break if cursor == '0'
    end
  rescue StandardError
    nil
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
