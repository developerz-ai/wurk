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

# Top-level for the same fork/Marshal reason as the sentinel above. Increments
# a shared counter every time perform is *invoked*, whether or not the run
# completes — the assertion that matters is how many times this fires across
# a hard-killed attempt plus a post-reboot retry, not just whether it
# eventually finishes.
class TimeoutRequeueSentinelWorker
  include Wurk::Job

  def perform(redis_url, attempt_key, done_key, sleep_seconds)
    client = RedisClient.config(url: redis_url).new_client
    client.call('INCR', attempt_key)
    client.call('EXPIRE', attempt_key, 60)
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

  POLL_TIMEOUT = 30.0
  POLL_INTERVAL = 0.1
  SHUTDOWN_TIMEOUT = 15

  # Second scenario: a job whose sleep outlasts a short shutdown_timeout, so
  # hard_shutdown fires for real. Job sleep must clear FAST_DRAIN_TIMEOUT by a
  # wide margin so the kill is deterministic; swarm-level timeouts must clear
  # the worst-case drain time (quiet settle + poll-to-deadline + hard_shutdown's
  # own 3s grace window) with room to spare.
  FAST_DRAIN_TIMEOUT = 2
  FAST_SWARM_TIMEOUT = 12
  TIMEOUT_JOB_SLEEP_SECONDS = 6
  REBOOT_DRAIN_TIMEOUT = 15
  REBOOT_SWARM_TIMEOUT = 20

  def setup
    super
    @ns = "gshut-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @started_key = "#{@ns}-started"
    @done_key = "#{@ns}-done"
    @attempt_key = "#{@ns}-attempts"
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    cleanup_observer_keys
    @observer&.close
  ensure
    super
  end

  def test_sigterm_to_parent_lets_in_flight_job_drain
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

  # The bug this closes: before the LREM-guarded bulk_requeue (fetcher/reliable.rb),
  # a job still in-flight when shutdown_timeout elapsed could end up duplicated
  # across the private and public lists, so a reboot could execute it a second
  # time *concurrently* with the about-to-be-killed original. Proves the fix
  # end to end: a job that sleeps past a short shutdown_timeout gets hard-killed
  # and requeued exactly once (private list empty, public queue holds one copy),
  # and a reboot that picks it back up runs it exactly once more — not twice.
  def test_job_killed_past_shutdown_timeout_is_requeued_and_runs_exactly_once_more
    push_timeout_job(sleep_seconds: TIMEOUT_JOB_SLEEP_SECONDS)

    first_pid = fork_swarm_supervisor(config_timeout: FAST_DRAIN_TIMEOUT, swarm_timeout: FAST_SWARM_TIMEOUT)
    begin
      assert wait_for_key(@attempt_key), 'job never started within poll timeout'

      ::Process.kill('TERM', first_pid)

      assert wait_for_pid_exit(first_pid, timeout: FAST_SWARM_TIMEOUT + 5),
             "supervisor pid #{first_pid} did not exit within its shutdown window"
    ensure
      reap_supervisor(first_pid)
    end

    refute @observer.call('GET', @done_key), 'job must not have completed before the hard kill'
    assert_equal '1', @observer.call('GET', @attempt_key), 'exactly one attempt before the timeout kill'
    assert_empty private_list_keys, 'bulk_requeue must leave no residual private-list entries'
    assert_equal 1, @observer.call('LLEN', public_queue_key), 'timed-out job must be requeued to the public queue'

    second_pid = fork_swarm_supervisor(config_timeout: REBOOT_DRAIN_TIMEOUT, swarm_timeout: REBOOT_SWARM_TIMEOUT)
    begin
      assert wait_for_key(@done_key), 'requeued job never completed after reboot'

      ::Process.kill('TERM', second_pid)

      assert wait_for_pid_exit(second_pid, timeout: REBOOT_SWARM_TIMEOUT + 5),
             "supervisor pid #{second_pid} did not exit within its shutdown window"
    ensure
      reap_supervisor(second_pid)
    end

    assert_equal '2', @observer.call('GET', @attempt_key),
                 'the reboot must run the requeued job exactly once more, not twice'
    assert_equal 0, @observer.call('LLEN', public_queue_key), 'completed job must not remain on the public queue'
    assert_empty private_list_keys, 'ack after completion must leave no residual private-list entries'
  end

  private

  def push_job(sleep_seconds:)
    config = build_config(SHUTDOWN_TIMEOUT)
    client = Wurk::Client.new(pool: capsule_pool(config), config: config)
    client.push('class' => GracefulShutdownSentinelWorker.name,
                'args' => [Wurk::Test.redis_url, @started_key, @done_key, sleep_seconds],
                'queue' => @queue_name)
  ensure
    config&.reset_redis_pools!
  end

  def push_timeout_job(sleep_seconds:)
    config = build_config(SHUTDOWN_TIMEOUT)
    client = Wurk::Client.new(pool: capsule_pool(config), config: config)
    client.push('class' => TimeoutRequeueSentinelWorker.name,
                'args' => [Wurk::Test.redis_url, @attempt_key, @done_key, sleep_seconds],
                'queue' => @queue_name)
  ensure
    config&.reset_redis_pools!
  end

  def build_config(timeout)
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:timeout] = timeout
    config
  end

  def capsule_pool(config)
    cap = config.default_capsule
    cap.queues = [@queue_name]
    cap.redis_pool
  end

  # Boots the swarm inside a subprocess so SIGTERM exercises the real
  # signal handler. install_signals: true is what we want to test.
  def fork_swarm_supervisor(count: 1, config_timeout: SHUTDOWN_TIMEOUT, swarm_timeout: SHUTDOWN_TIMEOUT)
    ::Process.fork do
      $stdout.reopen(IO::NULL)
      $stderr.reopen(IO::NULL)
      config = build_config(config_timeout)
      topology = Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
      swarm = Wurk::Swarm.new(topology: topology, config: config, shutdown_timeout: swarm_timeout)
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

    @observer.call('DEL', @started_key, @done_key, @attempt_key, public_queue_key)
    private_list_keys.each { |k| @observer.call('DEL', k) }
  rescue StandardError
    nil
  end

  def public_queue_key
    "#{Wurk::Keys::QUEUE_PREFIX}#{@queue_name}"
  end

  # Private lists are named `<public_queue>|<host>|<pid>|<nonce>|<idx>` (Reliable
  # .private_queue_name) — the pid belongs to the forked swarm child, which the
  # test never learns directly, so SCAN by prefix instead. Redis deletes a list
  # key outright once its last element is LREM'd/ACK'd, so "no matching keys"
  # is equivalent to "every private list is empty".
  def private_list_keys
    keys = []
    cursor = '0'
    loop do
      cursor, batch = @observer.call('SCAN', cursor, 'MATCH', "#{public_queue_key}|*", 'COUNT', 100)
      keys.concat(batch)
      break if cursor == '0'
    end
    keys
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
