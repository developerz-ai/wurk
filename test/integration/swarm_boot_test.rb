# frozen_string_literal: true

require_relative '../test_helper'

# Defined at the top level so Object.const_get(name) resolves the same
# way inside the forked child (which inherits the constant table but
# has no Minitest test-class lexical scope set up).
class SwarmBootSentinelWorker
  include Wurk::Job

  def perform(redis_url, sentinel_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', sentinel_key, ::Process.pid.to_s)
    client.call('EXPIRE', sentinel_key, 60)
  ensure
    client&.close
  end
end

# Real forks, real Redis, real perform. Boot a 2-child swarm, push a job,
# assert a child runs it. NEVER mock Redis here.
#
# Not parallelized — fork-from-thread is hazardous, and the swarm globally
# manipulates SIGTERM/INT handlers when signal install is enabled (the
# test opts out via `install_signals: false`).
class SwarmBootTest < Wurk::Test::UnitCase
  REDIS_URL = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
  POLL_TIMEOUT = 15.0
  POLL_INTERVAL = 0.1

  def setup
    super
    @ns = "swarmboot-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @sentinel_key = "#{@ns}-sentinel"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:timeout] = 5
    @observer_pool = RedisClient.config(url: REDIS_URL).new_client
  end

  def teardown
    @observer_pool&.call('DEL', @sentinel_key, "queue:#{@queue_name}",
                         private_queue_key(@queue_name))
    @observer_pool&.close
  ensure
    super
  end

  def test_swarm_boots_forks_and_runs_a_job_in_a_child # rubocop:disable Metrics/AbcSize,Minitest/MultipleAssertions
    push_sentinel_job
    swarm = Wurk::Swarm.new(topology: topology_n(2), config: @config, shutdown_timeout: 5)

    pids = swarm.boot(install_signals: false)

    begin
      assert_equal 2, pids.size, 'boot should return one PID per slot assignment'
      pids.each { |pid| assert pid_alive?(pid), "expected child #{pid} to be alive after boot" }

      supervisor = Thread.new { swarm.supervise }
      sentinel_pid = wait_for_sentinel

      assert sentinel_pid, "sentinel key #{@sentinel_key} was never written within #{POLL_TIMEOUT}s"
      refute_equal ::Process.pid.to_s, sentinel_pid,
                   'sentinel should have been written by a forked child, not the test process'
      assert_includes pids.map(&:to_s), sentinel_pid,
                      "sentinel writer #{sentinel_pid} should be one of the spawned children #{pids}"
    ensure
      swarm.shutdown(timeout: 5)
      supervisor&.join(10)
    end
  end

  def test_boot_raises_when_topology_is_empty
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.new, config: @config)
    assert_raises(ArgumentError) { swarm.boot(install_signals: false) }
  end

  def test_boot_is_not_re_entrant
    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: 5)
    swarm.boot(install_signals: false)
    begin
      assert_raises(RuntimeError) { swarm.boot(install_signals: false) }
    ensure
      swarm.shutdown(timeout: 5)
    end
  end

  private

  def topology_n(count)
    Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
  end

  def push_sentinel_job
    client = Wurk::Client.new(pool: capsule_pool, config: @config)
    client.push('class' => SwarmBootSentinelWorker.name,
                'args' => [REDIS_URL, @sentinel_key],
                'queue' => @queue_name)
  end

  def capsule_pool
    cap = @config.default_capsule
    cap.queues = [@queue_name]
    cap.redis_pool
  end

  def wait_for_sentinel
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      val = @observer_pool.call('GET', @sentinel_key)
      return val if val

      sleep POLL_INTERVAL
    end
    nil
  end

  def pid_alive?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def private_queue_key(queue_name)
    Wurk::Fetcher::Reliable.private_queue_name("queue:#{queue_name}")
  end
end
